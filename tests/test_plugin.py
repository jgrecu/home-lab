import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from templates.scripts.plugin import basename, nthhost


class TestBasename:
    def test_removes_j2_extension(self):
        assert basename("talos/talconfig.yaml.j2") == "talconfig.yaml"

    def test_handles_path_without_j2(self):
        assert basename("some/file.yaml") == "file"

    def test_handles_filename_only(self):
        assert basename("config.yaml.j2") == "config.yaml"


class TestNthhost:
    def test_first_host(self):
        assert nthhost("192.168.1.0/24", 1) == "192.168.1.1"

    def test_network_address(self):
        assert nthhost("10.0.0.0/16", 0) == "10.0.0.0"

    def test_last_host(self):
        assert nthhost("192.168.1.0/24", 255) == "192.168.1.255"

    def test_large_subnet(self):
        assert nthhost("10.0.0.0/8", 256) == "10.0.1.0"

    def test_non_strict_parsing(self):
        assert nthhost("10.0.0.1/24", 0) == "10.0.0.0"

    def test_raises_on_negative_query(self):
        with pytest.raises(ValueError, match="query=-1"):
            nthhost("10.0.0.0/24", -1)

    def test_raises_on_overflow_query(self):
        with pytest.raises(ValueError, match="query=256"):
            nthhost("10.0.0.0/24", 256)

    def test_raises_on_invalid_cidr(self):
        with pytest.raises(ValueError, match="not_a_cidr"):
            nthhost("not_a_cidr", 1)

    def test_ipv6(self):
        assert nthhost("fe80::/10", 1) == "fe80::1"
