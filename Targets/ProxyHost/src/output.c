/* SPDX-License-Identifier: GPL-3.0-only */
#include "output.h"

#include <stdlib.h>
#include <string.h>

struct px_event {
    uv_write_t write;
    uv_fs_t file_write;
    px_output *output;
    px_event *next;
    size_t length;
    size_t offset;
    char bytes[];
};

static void write_file(px_output *output);

static void wrote_stream(uv_write_t *request, int status) {
    px_event *event = request->data;
    px_output *output = event->output;
    --output->pending;
    output->pending_bytes -= event->length;
    free(event);
    if (status < 0) {
        px_output_stop(output);
        if (output->on_error) output->on_error(output->error_context);
    }
}

static void wrote_file(uv_fs_t *request) {
    px_event *event = request->data;
    px_output *output = event->output;
    ssize_t written = request->result;
    uv_fs_req_cleanup(request);
    if (written > 0) event->offset += (size_t)written;
    if (written <= 0) output->stopped = true;
    if (event->offset == event->length || output->stopped) {
        output->first = event->next;
        if (!output->first) output->last = NULL;
        --output->pending;
        output->pending_bytes -= event->length;
        free(event);
    }
    if (output->stopped) {
        while (output->first) {
            event = output->first;
            output->first = event->next;
            --output->pending;
            output->pending_bytes -= event->length;
            free(event);
        }
        output->last = NULL;
    } else write_file(output);
    if (written <= 0 && output->on_error) output->on_error(output->error_context);
}

static void write_file(px_output *output) {
    px_event *event = output->first;
    if (!event) return;
    uv_buf_t buffer = uv_buf_init(event->bytes + event->offset, (unsigned int)(event->length - event->offset));
    event->file_write.data = event;
    int status = uv_fs_write(output->loop, &event->file_write, 1, &buffer, 1, -1, wrote_file);
    if (status < 0) {
        event->file_write.result = status;
        wrote_file(&event->file_write);
    }
}

int px_output_init(px_output *output, uv_loop_t *loop) {
    memset(output, 0, sizeof(*output));
    output->loop = loop;
    uv_handle_type type = uv_guess_handle(1);
    if (type == UV_FILE) { output->file = true; return 0; }
    if (type == UV_TTY) {
        int status = uv_tty_init(loop, &output->tty, 1, 0);
        if (status < 0) return status;
        output->stream = (uv_stream_t *)&output->tty;
        return 0;
    }
    if (type != UV_NAMED_PIPE) return UV_EINVAL;
    int status = uv_pipe_init(loop, &output->pipe, 0);
    if (status < 0) return status;
    output->stream = (uv_stream_t *)&output->pipe;
    return uv_pipe_open(&output->pipe, 1);
}

bool px_output_send(px_output *output, const char *text) {
    if (output->stopped) return false;
    size_t length = strlen(text);
    if (length > 65536 || length > 524288 - output->pending_bytes || output->pending == PX_EVENT_LIMIT) {
        ++output->dropped;
        return false;
    }
    px_event *event = calloc(1, sizeof(*event) + length);
    if (!event) { ++output->dropped; return false; }
    event->output = output;
    event->length = length;
    memcpy(event->bytes, text, length);
    ++output->pending;
    output->pending_bytes += length;
    if (output->file) {
        if (output->last) output->last->next = event;
        else output->first = event;
        output->last = event;
        if (output->first == event) write_file(output);
    } else {
        event->write.data = event;
        uv_buf_t buffer = uv_buf_init(event->bytes, (unsigned int)length);
        int status = uv_write(&event->write, output->stream, &buffer, 1, wrote_stream);
        if (status < 0) wrote_stream(&event->write, status);
    }
    return !output->stopped;
}

void px_output_stop(px_output *output) {
    if (output->stopped) return;
    output->stopped = true;
    /* File writes finish asynchronously; a pipe consumer cannot delay shutdown. */
    if (output->stream && !uv_is_closing((uv_handle_t *)output->stream)) uv_close((uv_handle_t *)output->stream, NULL);
}
