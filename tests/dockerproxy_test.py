#!/usr/bin/env python3
"""Rules of dockerproxy/server.py against a fake daemon. Run: python3 tests/dockerproxy_test.py"""
import json, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dockerproxy"))
import server as px  # noqa: E402

MINE = {px.LABEL: "app"}
OTHER = {px.LABEL: "other"}


class FakeDaemon:
    def __init__(self):
        self.objs = {
            "/containers/web/json": {"Id": "c1web", "Config": {"Labels": MINE}},
            "/containers/theirs/json": {"Id": "c2theirs", "Config": {"Labels": OTHER}},
            "/containers/proj-app-docker-1/json": {"Id": "c3proxy", "Config": {"Labels": {}}},
            "/exec/e1/json": {"ContainerID": "c1web"},
            "/containers/c1web/json": {"Id": "c1web", "Config": {"Labels": MINE}},
            "/exec/e2/json": {"ContainerID": "c2theirs"},
            "/containers/c2theirs/json": {"Id": "c2theirs", "Config": {"Labels": OTHER}},
            "/volumes/data": {"Name": "data", "Labels": MINE},
            "/volumes/theirdata": {"Name": "theirdata", "Labels": OTHER},
            "/networks/mynet": {"Id": "n1", "Labels": MINE},
            "/networks/theirnet": {"Id": "n2", "Labels": OTHER},
            "/images/postgres:16/json": {"Id": "i1", "Config": {"Labels": None}},
            "/images/myimg:dev/json": {"Id": "i2", "Config": {"Labels": MINE}},
        }
        self.created = []

    def get(self, path):
        return self.objs.get(path)

    def call(self, method, path, body=None):
        self.created.append(body)
        return {}


class Rules(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.proj = os.path.join(os.path.realpath(self.tmp), "app")
        os.makedirs(os.path.join(self.proj, "src"))
        os.symlink("/etc", os.path.join(self.proj, "escape"))
        px.PROJECT, px.PROJECT_DIR = "app", self.proj
        self.d = FakeDaemon()

    def route(self, method, path, query=None, body=None):
        return px.route(method, path, list((query or {}).items()), body, self.d)

    def denied(self, method, path, query=None, body=None):
        with self.assertRaises(px.Deny):
            self.route(method, path, query, body)

    def create(self, host=None, **cfg):
        cfg.setdefault("Image", "alpine")
        if host is not None:
            cfg["HostConfig"] = host
        return self.route("POST", "/containers/create", body=cfg)[2]

    def create_denied(self, host=None, **cfg):
        with self.assertRaises(px.Deny):
            self.create(host, **cfg)

    # basics
    def test_ping_version_info(self):
        for p in ("/_ping", "/version", "/info"):
            self.route("GET", p)
        self.route("HEAD", "/_ping")

    def test_everything_else_denied(self):
        for m, p in (("GET", "/system/df"), ("POST", "/swarm/init"), ("GET", "/plugins"), ("POST", "/session"),
                     ("POST", "/grpc"), ("POST", "/commit"), ("POST", "/images/load"), ("POST", "/auth")):
            self.denied(m, p)

    # listing
    def test_container_list_forces_label(self):
        q = dict(self.route("GET", "/containers/json", {"all": "1"})[1])
        self.assertEqual(json.loads(q["filters"]), {"label": {"agent-hub.project=app": True}})
        self.assertEqual(q["all"], "1")

    def test_label_filter_merges_list_form(self):
        q = dict(self.route("GET", "/volumes", {"filters": '{"label":["x=1"],"dangling":["true"]}'})[1])
        self.assertEqual(json.loads(q["filters"]),
                         {"label": {"x=1": True, "agent-hub.project=app": True}, "dangling": ["true"]})
        dict(self.route("GET", "/networks")[1])["filters"]
        dict(self.route("GET", "/events")[1])["filters"]

    # create
    def test_create_injects_label_over_spoofed_one(self):
        self.assertEqual(self.create(Labels={px.LABEL: "other", "a": "b"})["Labels"], {px.LABEL: "app", "a": "b"})

    def test_bind_inside_project_allowed_and_resolved(self):
        b = self.create({"Binds": [self.proj + "/src:/app:ro"]})
        self.assertEqual(b["HostConfig"]["Binds"], [self.proj + "/src:/app:ro"])
        self.create({"Binds": [self.proj + ":/app"]})
        self.create({"Mounts": [{"Type": "bind", "Source": self.proj + "/src", "Target": "/app"}]})

    def test_bind_outside_denied(self):
        for src in ("/Users/x/.agent-hub", self.proj + "/../other", self.proj + "/escape", self.proj + "/escape/x",
                    self.proj + "x", "/var/run/docker.sock", "/"):
            self.create_denied({"Binds": [src + ":/x"]})
            self.create_denied({"Mounts": [{"Type": "bind", "Source": src, "Target": "/x"}]})

    def test_privileges_denied(self):
        for h in ({"Privileged": True}, {"CapAdd": ["SYS_ADMIN"]}, {"Devices": [{"PathOnHost": "/dev/sda"}]},
                  {"PidMode": "host"}, {"IpcMode": "host"}, {"UsernsMode": "host"}, {"UTSMode": "host"},
                  {"CgroupnsMode": "host"}, {"NetworkMode": "host"}, {"SecurityOpt": ["seccomp=unconfined"]},
                  {"SecurityOpt": ["apparmor=unconfined"]}, {"SecurityOpt": ["label=disable"]},
                  {"MaskedPaths": []}, {"Runtime": "kata"}, {"CgroupParent": "/"}, {"VolumeDriver": "x"}):
            self.create_denied(h)

    def test_go_style_keys_cannot_bypass(self):
        self.create_denied({"privileged": True})
        self.create_denied({"ſecurityOpt": ["seccomp=unconfined"]})  # Go folds ſ to s
        self.create_denied(hostConfig={"Privileged": True})
        with self.assertRaises(px.Deny):
            px.loads('{"HostConfig":{"Privileged":false,"privileged":true}}')

    def test_allowed_settings(self):
        self.create({"PortBindings": {"5432/tcp": [{"HostPort": "5432"}]}, "SecurityOpt": ["no-new-privileges"],
                     "NetworkMode": "default", "IpcMode": "private", "Tmpfs": {"/run": ""}})
        self.create({"NetworkMode": "mynet"}, NetworkingConfig={"EndpointsConfig": {"mynet": {}}})

    def test_other_projects_namespaces_and_networks(self):
        for h in ({"NetworkMode": "theirnet"}, {"NetworkMode": "container:theirs"}, {"PidMode": "container:theirs"},
                  {"VolumesFrom": ["theirs:ro"]}, {"NetworkMode": "proj-other_default"}):
            self.create_denied(h)
        self.create_denied({}, NetworkingConfig={"EndpointsConfig": {"theirnet": {}}})
        self.create({"NetworkMode": "container:web", "VolumesFrom": ["web"]})

    def test_named_volumes(self):
        self.create({"Binds": ["data:/data"]})
        self.create_denied({"Binds": ["theirdata:/data"]})
        self.create_denied({"Mounts": [{"Type": "volume", "Source": "theirdata", "Target": "/d"}]})
        self.create({"Binds": ["fresh:/data"]})
        self.assertEqual(self.d.created[-1], {"Name": "fresh", "Labels": {px.LABEL: "app"}})
        self.create_denied({"Mounts": [{"Type": "volume", "Target": "/d", "VolumeOptions": {"DriverConfig": {
            "Name": "local", "Options": {"type": "none", "o": "bind", "device": "/Users"}}}}]})
        self.create_denied({"Mounts": [{"Type": "npipe", "Source": "x", "Target": "/d"}]})

    # existing containers and execs
    def test_own_container_ops_rewritten_to_id(self):
        self.assertEqual(self.route("POST", "/containers/web/start")[0], "/containers/c1web/start")
        self.assertEqual(self.route("DELETE", "/containers/web")[0], "/containers/c1web")
        self.route("POST", "/containers/web/attach")
        self.route("POST", "/containers/web/exec", body={"Cmd": ["sh"]})
        self.route("POST", "/exec/e1/start")

    def test_other_containers_denied(self):
        for m, p in (("POST", "/containers/theirs/exec"), ("DELETE", "/containers/theirs"),
                     ("GET", "/containers/theirs/json"), ("POST", "/containers/theirs/attach"),
                     ("POST", "/containers/proj-app-docker-1/exec"), ("POST", "/containers/missing/start"),
                     ("POST", "/exec/e2/start"), ("POST", "/containers/prune"), ("GET", "/containers/../x/json")):
            self.denied(m, p)

    def test_missing_objects_are_404(self):  # compose creates networks/volumes after a 404 on inspect
        for p in ("/networks/newnet", "/volumes/newvol", "/containers/missing/json"):
            with self.assertRaises(px.NotFound):
                self.route("GET", p)

    def test_privileged_exec_denied(self):
        self.denied("POST", "/containers/web/exec", body={"Cmd": ["sh"], "Privileged": True})

    # volumes and networks
    def test_volumes(self):
        self.assertEqual(self.route("POST", "/volumes/create", body={"Name": "v"})[2]["Labels"], {px.LABEL: "app"})
        self.route("POST", "/volumes/create", body={"DriverOpts": {"type": "tmpfs", "device": "tmpfs"}})
        self.denied("POST", "/volumes/create", body={"DriverOpts": {"type": "none", "o": "bind", "device": "/"}})
        self.route("DELETE", "/volumes/data")
        self.denied("DELETE", "/volumes/theirdata")
        self.denied("GET", "/volumes/theirdata")
        self.denied("POST", "/volumes/prune")

    def test_networks(self):
        self.assertEqual(self.route("POST", "/networks/create", body={"Name": "n"})[2]["Labels"], {px.LABEL: "app"})
        self.denied("POST", "/networks/create", body={"Name": "n", "Driver": "macvlan"})
        self.assertEqual(self.route("DELETE", "/networks/mynet")[0], "/networks/n1")
        self.denied("DELETE", "/networks/theirnet")
        self.route("POST", "/networks/mynet/connect", body={"Container": "web"})
        self.denied("POST", "/networks/mynet/connect", body={"Container": "theirs"})
        self.denied("POST", "/networks/theirnet/connect", body={"Container": "web"})

    # images
    def test_images(self):
        self.route("GET", "/images/json")
        self.route("GET", "/images/library/postgres:16/json")
        self.route("POST", "/images/create", {"fromImage": "postgres", "tag": "16"})
        for m, p, q in (("DELETE", "/images/postgres:16", {}), ("POST", "/images/prune", {}),
                        ("POST", "/build/prune", {}), ("POST", "/images/create", {"fromSrc": "-", "repo": "x"}),
                        ("POST", "/images/create", {"fromImage": "docker.io/library/agent-hub", "tag": "base"})):
            self.denied(m, p, q)

    def test_build_and_tag_targets(self):
        q = dict(self.route("POST", "/build", {"t": "newimg:1", "labels": '{"a":"b"}'})[1])
        self.assertEqual(json.loads(q["labels"]), {"a": "b", px.LABEL: "app"})
        self.route("POST", "/build", {"t": "myimg:dev"})
        for t in ("agent-hub:base", "agent-hub:dockerproxy", "docker.io/library/agent-hub:rust", "postgres:16"):
            self.denied("POST", "/build", {"t": t})
        self.denied("POST", "/build", {"networkmode": "host"})
        self.denied("POST", "/build", {"version": "2"})
        self.route("POST", "/images/postgres:16/tag", {"repo": "mypg", "tag": "1"})
        self.denied("POST", "/images/myimg:dev/tag", {"repo": "agent-hub", "tag": "base"})
        self.denied("POST", "/images/myimg:dev/tag", {"repo": "postgres", "tag": "16"})


if __name__ == "__main__":
    unittest.main(verbosity=1)
