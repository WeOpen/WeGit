"""Expose website-owned build checks to the repository CI test discovery."""
import importlib.util
from pathlib import Path

path = Path(__file__).resolve().parents[3] / "site/tests/test_build.py"
spec = importlib.util.spec_from_file_location("wegit_website_tests", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
WebsiteBuildTests = module.WebsiteBuildTests

server_path = Path(__file__).resolve().parents[3] / "site/tests/test_server.py"
server_spec = importlib.util.spec_from_file_location("wegit_website_server_tests", server_path)
server_module = importlib.util.module_from_spec(server_spec)
server_spec.loader.exec_module(server_module)
WebsiteErrorRouteTests = server_module.ErrorRouteTests
