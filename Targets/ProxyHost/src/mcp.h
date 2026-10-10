/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef THREADING_PROXY_MCP_H
#define THREADING_PROXY_MCP_H
#include "proxy.h"
#include "output.h"

typedef struct px_mcp px_mcp;
px_mcp *px_mcp_create(uv_loop_t *loop, px_config config, px_output *output);
/* One newline-free message, bounded to 64 KiB by the transport. False terminates the lease. */
bool px_mcp_receive(px_mcp *mcp, const char *line, size_t length);
void px_mcp_stop(px_mcp *mcp);
/* Only after the loop has drained. */
void px_mcp_destroy(px_mcp *mcp);
#endif
