"""Start the upstream Water MCP with local compatibility fixes."""

import runpy

import utils_xz
from briefing_compat import install as install_briefing_compat
from related_page_compat import install as install_related_pages
from realtime_forecast_compat import install as install_realtime_forecast_compat
from zhixun_core_v2_compat import install


install(utils_xz)

import get_url_server
import mcp_server_briefing
import mcp_server_realtime_forecast
import mcp_server_xz

# Patch functions before mcp_server_unified imports and registers them.
install_related_pages(mcp_server_xz, get_url_server)
install_briefing_compat(mcp_server_briefing)
install_realtime_forecast_compat(
    mcp_server_realtime_forecast,
    mcp_server_realtime_forecast.REALTIME_FORECAST_BASE_URL,
)
runpy.run_module("mcp_server_unified", run_name="__main__")
