#include "LinuxWindowBridge.h"
#include "AccessibilityInternal.h"
#ifdef __linux__
#include <atk/atk.h>
#include <atk-bridge.h>
#include <SDL2/SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_VISIBLE_ROWS = 32, MAX_ROW_NAME = 512, MAX_ROW_ID = 64,
       MAX_TERMINAL_TEXT = 64 * 1024 };

typedef struct {
    AtkObject parent;
    GPtrArray *children;
    char *id;
    AtkRectangle bounds;
    int row, selected, canOpen, retired;
} AccessibleNode;
typedef struct { AtkObjectClass parent; } AccessibleNodeClass;

static void action_interface_init(AtkActionIface *iface);
G_DEFINE_TYPE_WITH_CODE(AccessibleNode, accessible_node, ATK_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_ACTION, action_interface_init))

typedef struct { AccessibleNode parent; } ComponentNode;
typedef struct { AccessibleNodeClass parent; } ComponentNodeClass;
static void component_interface_init(AtkComponentIface *iface);
G_DEFINE_TYPE_WITH_CODE(ComponentNode, component_node, accessible_node_get_type(),
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, component_interface_init))

typedef struct {
    ComponentNode parent;
    char *text;
    int length, characters, caret;
} TerminalNode;
typedef struct { ComponentNodeClass parent; } TerminalNodeClass;
static void text_interface_init(AtkTextIface *iface);
G_DEFINE_TYPE_WITH_CODE(TerminalNode, terminal_node, component_node_get_type(),
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_TEXT, text_interface_init))

static AccessibleNode *app, *frame, *list;
static TerminalNode *terminal;
static AccessibleNode *activeList;
static AccessibleNode *focused;
static TWWindow *hostWindow;
static uint32_t eventType = UINT32_MAX, generation = 1;
static int bridgeReady, windowFocused;
static struct {
    char title[128];
    int first, total, count, canOpen;
    AtkRectangle bounds;
    struct { char id[MAX_ROW_ID], name[MAX_ROW_NAME]; int selected; AtkRectangle bounds; } rows[MAX_VISIBLE_ROWS];
} pending;

static gint node_child_count(AtkObject *object) {
    return (gint)((AccessibleNode *)object)->children->len;
}
static AtkObject *node_ref_child(AtkObject *object, gint index) {
    AccessibleNode *node = (AccessibleNode *)object;
    if (index < 0 || (guint)index >= node->children->len) return NULL;
    return g_object_ref(g_ptr_array_index(node->children, (guint)index));
}
static gint node_index(AtkObject *object) {
    AccessibleNode *node = (AccessibleNode *)object;
    AtkObject *parent = atk_object_get_parent(object);
    if (!parent) return -1;
    GPtrArray *children = ((AccessibleNode *)parent)->children;
    for (guint i = 0; i < children->len; i++)
        if (g_ptr_array_index(children, i) == node) return (gint)i;
    return -1;
}
static int node_mounted(AtkObject *object) {
    for (int depth = 0; object && depth < 8; depth++) {
        if (object == ATK_OBJECT(app)) return 1;
        object = atk_object_get_parent(object);
    }
    return 0;
}
static AtkStateSet *node_state(AtkObject *object) {
    AccessibleNode *node = (AccessibleNode *)object;
    AtkStateSet *states = atk_state_set_new();
    if (node->retired) {
        atk_state_set_add_state(states, ATK_STATE_DEFUNCT);
        return states;
    }
    atk_state_set_add_state(states, ATK_STATE_ENABLED);
    atk_state_set_add_state(states, ATK_STATE_SENSITIVE);
    if (node == list || node == (AccessibleNode *)terminal || node->row >= 0) {
        atk_state_set_add_state(states, ATK_STATE_FOCUSABLE);
        if (node == focused) atk_state_set_add_state(states, ATK_STATE_FOCUSED);
    }
    if (node_mounted(object)) {
        atk_state_set_add_state(states, ATK_STATE_VISIBLE);
        atk_state_set_add_state(states, ATK_STATE_SHOWING);
    }
    if (node->row >= 0) {
        atk_state_set_add_state(states, ATK_STATE_SELECTABLE);
        if (node->selected) {
            atk_state_set_add_state(states, ATK_STATE_SELECTED);
        }
    }
    return states;
}
static void node_finalize(GObject *object) {
    AccessibleNode *node = (AccessibleNode *)object;
    g_ptr_array_unref(node->children);
    g_free(node->id);
    G_OBJECT_CLASS(accessible_node_parent_class)->finalize(object);
}
static void accessible_node_class_init(AccessibleNodeClass *klass) {
    AtkObjectClass *atk = ATK_OBJECT_CLASS(klass);
    atk->get_n_children = node_child_count;
    atk->ref_child = node_ref_child;
    atk->get_index_in_parent = node_index;
    atk->ref_state_set = node_state;
    G_OBJECT_CLASS(klass)->finalize = node_finalize;
}
static void accessible_node_init(AccessibleNode *node) {
    node->children = g_ptr_array_new_with_free_func(g_object_unref);
    node->row = -1;
}
static AccessibleNode *new_node(AtkRole role, const char *name) {
    AccessibleNode *node = g_object_new(accessible_node_get_type(), NULL);
    atk_object_set_role(ATK_OBJECT(node), role);
    atk_object_set_name(ATK_OBJECT(node), name);
    return node;
}
static AccessibleNode *new_component(AtkRole role, const char *name) {
    AccessibleNode *node = g_object_new(component_node_get_type(), NULL);
    atk_object_set_role(ATK_OBJECT(node), role);
    atk_object_set_name(ATK_OBJECT(node), name);
    return node;
}
static void set_name_if_changed(AccessibleNode *node, const char *name) {
    const char *current = atk_object_get_name(ATK_OBJECT(node));
    if (!current || strcmp(current, name) != 0) atk_object_set_name(ATK_OBJECT(node), name);
}
static void set_description_if_changed(AccessibleNode *node, const char *description) {
    const char *current = atk_object_get_description(ATK_OBJECT(node));
    if (!current || strcmp(current, description) != 0)
        atk_object_set_description(ATK_OBJECT(node), description);
}
static void add_child(AccessibleNode *parent, AccessibleNode *child) {
    atk_object_set_parent(ATK_OBJECT(child), ATK_OBJECT(parent));
    g_ptr_array_add(parent->children, g_object_ref(child));
    g_signal_emit_by_name(parent, "children-changed::add", parent->children->len - 1, child);
}
static void clear_children(AccessibleNode *parent) {
    while (parent->children->len) {
        guint index = parent->children->len - 1;
        AccessibleNode *child = g_ptr_array_index(parent->children, index);
        g_signal_emit_by_name(parent, "children-changed::remove", index, child);
        if (child->row >= 0) child->retired = 1;
        atk_object_set_parent(ATK_OBJECT(child), NULL);
        g_ptr_array_remove_index(parent->children, index);
    }
}
static void set_focused(AccessibleNode *next) {
    if (focused == next) return;
    AccessibleNode *old = focused;
    focused = next ? g_object_ref(next) : NULL;
    if (old) {
        atk_object_notify_state_change(ATK_OBJECT(old), ATK_STATE_FOCUSED, FALSE);
        g_object_unref(old);
    }
    if (focused) atk_object_notify_state_change(ATK_OBJECT(focused), ATK_STATE_FOCUSED, TRUE);
}
static void refresh_focus(void) {
    AccessibleNode *next = NULL;
    if (windowFocused && frame && frame->children->len == 1) {
        AccessibleNode *content = g_ptr_array_index(frame->children, 0);
        if (content == list) {
            next = list;
            for (guint i = 0; i < list->children->len; i++) {
                AccessibleNode *row = g_ptr_array_index(list->children, i);
                if (row->selected) { next = row; break; }
            }
        } else if (content == (AccessibleNode *)terminal) next = content;
    }
    set_focused(next);
}
static void show_content(AccessibleNode *content) {
    if (!frame) return;
    if (frame->children->len == 1 && g_ptr_array_index(frame->children, 0) == content) {
        refresh_focus();
        return;
    }
    set_focused(NULL);
    clear_children(frame);
    add_child(frame, content);
    activeList = content == list ? list : NULL;
    generation++;
    refresh_focus();
}
static AtkObject *get_root(void) { return ATK_OBJECT(app); }
static const gchar *get_toolkit_name(void) { return "Threading Linux bridge"; }
static const gchar *get_toolkit_version(void) { return "0"; }

static gint action_count(AtkAction *action) {
    AccessibleNode *node = (AccessibleNode *)action;
    return node->row < 0 ? 0 : (node->canOpen ? 2 : 1);
}
static const gchar *action_name(AtkAction *action, gint index) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (node->row < 0) return NULL;
    return index == 0 ? "select" : (index == 1 && node->canOpen ? "open" : NULL);
}
static gboolean action_do(AtkAction *action, gint index) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (!activeList || node->row < 0 || (guint)node->row >= activeList->children->len
        || g_ptr_array_index(activeList->children, (guint)node->row) != node
        || index < 0 || index >= action_count(action) || eventType == UINT32_MAX) return FALSE;
    SDL_Event event = {0};
    event.type = eventType;
    event.user.code = 1;
    event.user.data1 = (void *)(intptr_t)node->row;
    event.user.data2 = (void *)(uintptr_t)generation;
    if (SDL_PushEvent(&event) != 1) return FALSE;
    if (index == 1) {
        event.user.code = 2;
        if (SDL_PushEvent(&event) != 1) return FALSE;
    }
    return TRUE;
}
static void action_interface_init(AtkActionIface *iface) {
    iface->get_n_actions = action_count;
    iface->get_name = action_name;
    iface->do_action = action_do;
}

static int component_rectangle(AtkObject *object, AtkCoordType coordinates,
                               gint *x, gint *y, gint *width, gint *height) {
    AccessibleNode *node = (AccessibleNode *)object;
    if (!hostWindow || node->retired || !node_mounted(object)) return 0;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(hostWindow, &originX, &originY, &windowWidth, &windowHeight);
    if (object == ATK_OBJECT(frame) || object == ATK_OBJECT(terminal)) {
        *x = 0; *y = 0; *width = windowWidth; *height = windowHeight;
    } else if (object == ATK_OBJECT(list)) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (node->row >= 0 && atk_object_get_parent(object) == ATK_OBJECT(list)) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else return 0;
    if (coordinates == ATK_XY_SCREEN) { *x += originX; *y += originY; }
    else if (coordinates == ATK_XY_PARENT && node->row >= 0) {
        *x -= list->bounds.x; *y -= list->bounds.y;
    }
    else if (coordinates != ATK_XY_WINDOW && coordinates != ATK_XY_PARENT) return 0;
    return 1;
}
static void component_extents(AtkComponent *component, gint *x, gint *y,
                              gint *width, gint *height, AtkCoordType coordinates) {
    gint resultX, resultY, resultWidth, resultHeight;
    if (!component_rectangle(ATK_OBJECT(component), coordinates,
                             &resultX, &resultY, &resultWidth, &resultHeight)) {
        resultX = resultY = resultWidth = resultHeight = -1;
    }
    if (x) *x = resultX;
    if (y) *y = resultY;
    if (width) *width = resultWidth;
    if (height) *height = resultHeight;
}
static AtkObject *component_child_at(AtkComponent *component, gint x, gint y,
                                      AtkCoordType coordinates) {
    AccessibleNode *node = (AccessibleNode *)component;
    if (!node_mounted(ATK_OBJECT(node))) return NULL;
    // The only containers are the frame and list. Both parents start at the window origin;
    // convert the caller's point once, then compare children in window coordinates.
    if (coordinates == ATK_XY_SCREEN) {
        int originX, originY, width, height;
        tw_window_geometry(hostWindow, &originX, &originY, &width, &height);
        x -= originX; y -= originY;
    } else if (coordinates != ATK_XY_WINDOW && coordinates != ATK_XY_PARENT) return NULL;
    for (guint i = 0; i < node->children->len; i++) {
        AtkObject *child = g_ptr_array_index(node->children, i);
        if (ATK_IS_COMPONENT(child) && atk_component_contains(ATK_COMPONENT(child), x, y, ATK_XY_WINDOW))
            return g_object_ref(child);
    }
    return NULL;
}
static void component_interface_init(AtkComponentIface *iface) {
    iface->get_extents = component_extents;
    iface->ref_accessible_at_point = component_child_at;
}
static void component_node_class_init(ComponentNodeClass *klass) { (void)klass; }
static void component_node_init(ComponentNode *node) { (void)node; }

static gchar *terminal_get_text(AtkText *text, gint start, gint end) {
    TerminalNode *node = (TerminalNode *)text;
    if (start < 0 || start > node->characters || end < -1) return g_strdup("");
    if (end == -1 || end > node->characters) end = node->characters;
    if (end < start) return g_strdup("");
    const char *first = g_utf8_offset_to_pointer(node->text, start);
    const char *last = g_utf8_offset_to_pointer(first, end - start);
    return g_strndup(first, (gsize)(last - first));
}
static gunichar terminal_character(AtkText *text, gint offset) {
    TerminalNode *node = (TerminalNode *)text;
    if (offset < 0 || offset >= node->characters) return 0;
    return g_utf8_get_char(g_utf8_offset_to_pointer(node->text, offset));
}
static gint terminal_character_count(AtkText *text) {
    return ((TerminalNode *)text)->characters;
}
static gint terminal_caret(AtkText *text) {
    return ((TerminalNode *)text)->caret;
}
static gint terminal_selections(AtkText *text) { (void)text; return 0; }
static gboolean word_character(gunichar value) {
    return g_unichar_isalnum(value) || value == '_';
}
static gchar *terminal_string_at(AtkText *text, gint offset, AtkTextGranularity granularity,
                                 gint *start, gint *end) {
    TerminalNode *node = (TerminalNode *)text;
    *start = *end = -1;
    if (offset < 0 || offset >= node->characters) return NULL;
    const char *begin = node->text;
    const char *limit = begin + node->length;
    const char *here = g_utf8_offset_to_pointer(begin, offset);
    const char *left = here, *right = g_utf8_next_char(here);
    int first = offset, last = offset + 1;
    if (granularity == ATK_TEXT_GRANULARITY_WORD) {
        if (!word_character(g_utf8_get_char(left)) && left > begin) {
            left = g_utf8_prev_char(left); first--;
        }
        gboolean inWord = word_character(g_utf8_get_char(left));
        right = left;
        last = first;
        while (left > begin) {
            const char *previous = g_utf8_prev_char(left);
            if (word_character(g_utf8_get_char(previous)) != inWord) break;
            left = previous; first--;
        }
        while (right < limit && word_character(g_utf8_get_char(right)) == inWord) {
            right = g_utf8_next_char(right); last++;
        }
    } else if (granularity == ATK_TEXT_GRANULARITY_LINE ||
               granularity == ATK_TEXT_GRANULARITY_PARAGRAPH) {
        while (left > begin) {
            const char *previous = g_utf8_prev_char(left);
            if (g_utf8_get_char(previous) == '\n') break;
            left = previous; first--;
        }
        right = here; last = offset;
        while (right < limit && g_utf8_get_char(right) != '\n') {
            right = g_utf8_next_char(right); last++;
        }
        if (right < limit) { right++; last++; }
    } else if (granularity != ATK_TEXT_GRANULARITY_CHAR) {
        return NULL;
    }
    *start = first; *end = last;
    return g_strndup(left, (gsize)(right - left));
}
static void text_interface_init(AtkTextIface *iface) {
    iface->get_text = terminal_get_text;
    iface->get_character_at_offset = terminal_character;
    iface->get_character_count = terminal_character_count;
    iface->get_caret_offset = terminal_caret;
    iface->get_n_selections = terminal_selections;
    iface->get_string_at_offset = terminal_string_at;
}
static void terminal_node_finalize(GObject *object) {
    g_free(((TerminalNode *)object)->text);
    G_OBJECT_CLASS(terminal_node_parent_class)->finalize(object);
}
static void terminal_node_class_init(TerminalNodeClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = terminal_node_finalize;
}
static void terminal_node_init(TerminalNode *node) {
    node->text = g_strdup("");
    node->caret = -1;
}
static void set_terminal_text(const char *value, int length, int caret) {
    if (!terminal) return;
    if (!value) { value = ""; length = 0; caret = -1; }
    if (length < 0 || length > MAX_TERMINAL_TEXT ||
        memchr(value, 0, (size_t)length) || !g_utf8_validate(value, length, NULL)) return;
    int characters = (int)g_utf8_strlen(value, length);
    if (caret < -1 || caret > characters) caret = -1;
    int changed = terminal->length != length || memcmp(terminal->text, value, (size_t)length) != 0;
    int oldCaret = terminal->caret;
    if (changed) {
        char *oldText = terminal->text;
        const char *oldFirst = oldText, *newFirst = value;
        const char *oldLast = oldText + terminal->length, *newLast = value + length;
        int firstCharacter = 0;
        while (oldFirst < oldLast && newFirst < newLast &&
               g_utf8_get_char(oldFirst) == g_utf8_get_char(newFirst)) {
            oldFirst = g_utf8_next_char(oldFirst);
            newFirst = g_utf8_next_char(newFirst);
            firstCharacter++;
        }
        while (oldLast > oldFirst && newLast > newFirst) {
            const char *oldPrevious = g_utf8_prev_char(oldLast);
            const char *newPrevious = g_utf8_prev_char(newLast);
            if (g_utf8_get_char(oldPrevious) != g_utf8_get_char(newPrevious)) break;
            oldLast = oldPrevious; newLast = newPrevious;
        }
        int removed = (int)g_utf8_strlen(oldFirst, oldLast - oldFirst);
        int inserted = (int)g_utf8_strlen(newFirst, newLast - newFirst);
        char *removedText = removed ? g_strndup(oldFirst, (gsize)(oldLast - oldFirst)) : NULL;
        char *insertedText = inserted ? g_strndup(newFirst, (gsize)(newLast - newFirst)) : NULL;
        terminal->text = g_strndup(value, (gsize)length);
        terminal->length = length;
        terminal->characters = characters;
        // Emit only the changed Unicode span; the source is one bounded visible frame.
        if (removed) g_signal_emit_by_name(terminal, "text-remove::system", firstCharacter, removed, removedText);
        if (inserted) g_signal_emit_by_name(terminal, "text-insert::system", firstCharacter, inserted, insertedText);
        g_free(removedText);
        g_free(insertedText);
        g_free(oldText);
    }
    terminal->caret = caret;
    if (oldCaret != caret) g_signal_emit_by_name(terminal, "text-caret-moved", caret);
}

void tw_accessibility_open(TWWindow *window) {
    if (!getenv("DBUS_SESSION_BUS_ADDRESS") || bridgeReady) return;
    hostWindow = window;
    eventType = SDL_RegisterEvents(1);
    app = new_node(ATK_ROLE_APPLICATION, "Threading Linux");
    frame = new_component(ATK_ROLE_FRAME, "Threading Linux window");
    list = new_component(ATK_ROLE_LIST, "Projects");
    terminal = g_object_new(terminal_node_get_type(), NULL);
    atk_object_set_role(ATK_OBJECT(terminal), ATK_ROLE_TERMINAL);
    atk_object_set_name(ATK_OBJECT(terminal), "Terminal");
    atk_object_set_description(ATK_OBJECT(terminal), "Visible terminal screen; read only.");
    add_child(app, frame);
    add_child(frame, list);
    activeList = list;
    AtkUtilClass *util = ATK_UTIL_CLASS(g_type_class_ref(ATK_TYPE_UTIL));
    util->get_root = get_root;
    util->get_toolkit_name = get_toolkit_name;
    util->get_toolkit_version = get_toolkit_version;
    g_type_class_unref(util);
    bridgeReady = atk_bridge_adaptor_init(NULL, NULL) == 0;
    if (!bridgeReady) {
        eventType = UINT32_MAX;
        g_warning("Threading AT-SPI bridge could not start");
    }
}
void tw_accessibility_close(void) {
    if (!app) return;
    set_focused(NULL);
    if (bridgeReady) atk_bridge_adaptor_cleanup();
    bridgeReady = 0; activeList = NULL; eventType = UINT32_MAX; windowFocused = 0;
    clear_children(list);
    clear_children(frame);
    clear_children(app);
    g_clear_object(&app);
    g_clear_object(&frame);
    g_clear_object(&list);
    g_clear_object(&terminal);
    hostWindow = NULL;
    generation++;
}
void tw_accessibility_poll(void) {
    if (!bridgeReady) return;
    for (int i = 0; i < 8 && g_main_context_pending(NULL); i++)
        g_main_context_iteration(NULL, FALSE);
}
void tw_accessibility_title(const char *title) {
    if (!frame || !title) return;
    set_name_if_changed(frame, strnlen(title, 512) < 512 ? title : "[window title exceeds 512 bytes]");
}
uint32_t tw_accessibility_event_type(void) { return eventType; }
int tw_accessibility_event_is_current(uint32_t value) { return bridgeReady && value == generation; }
int tw_accessibility_row_center(int row, int *x, int *y) {
    if (!bridgeReady || !activeList || row < 0 || (guint)row >= activeList->children->len) return 0;
    AccessibleNode *node = g_ptr_array_index(activeList->children, (guint)row);
    if (node->retired || node->bounds.width <= 0 || node->bounds.height <= 0) return 0;
    *x = node->bounds.x + node->bounds.width / 2;
    *y = node->bounds.y + node->bounds.height / 2;
    return 1;
}
void tw_accessibility_window_focus(TWWindow *window, int hasFocus) {
    (void)window;
    if (!bridgeReady || windowFocused == (hasFocus != 0)) return;
    windowFocused = hasFocus != 0;
    refresh_focus();
}

void tw_accessibility_begin_list(TWWindow *window, const char *name, int first, int total, int canOpen,
                                 int x, int y, int width, int height) {
    (void)window;
    if (!bridgeReady) return;
    pending.count = 0;
    pending.first = first;
    pending.total = total;
    pending.canOpen = canOpen;
    pending.bounds = (AtkRectangle){x, y, width, height};
    g_strlcpy(pending.title, name ? name : "Items", sizeof(pending.title));
}
int tw_accessibility_add_row(TWWindow *window, const char *id, const char *name, int selected,
                             int x, int y, int width, int height) {
    if (!bridgeReady) return 0;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    if (!id || !name || pending.count >= MAX_VISIBLE_ROWS
        || strnlen(id, MAX_ROW_ID) == MAX_ROW_ID
        || strnlen(name, MAX_ROW_NAME) == MAX_ROW_NAME
        || !g_utf8_validate(name, -1, NULL)
        || x < 0 || x >= windowWidth || width <= 0 || width > windowWidth - x
        || y < 0 || y >= windowHeight || height <= 0 || height > windowHeight - y) return -1;
    int index = pending.count++;
    strcpy(pending.rows[index].id, id);
    strcpy(pending.rows[index].name, name);
    pending.rows[index].selected = selected != 0;
    pending.rows[index].bounds = (AtkRectangle){x, y, width, height};
    return 0;
}
void tw_accessibility_end_list(TWWindow *window) {
    (void)window;
    if (!bridgeReady) return;
    set_name_if_changed(list, pending.title);
    list->bounds = pending.bounds;
    char description[128];
    snprintf(description, sizeof(description), "Showing %d through %d of %d items",
             pending.count ? pending.first + 1 : 0, pending.first + pending.count, pending.total);
    set_description_if_changed(list, description);
    int same = list->children->len == (guint)pending.count;
    for (int i = 0; same && i < pending.count; i++) {
        AccessibleNode *row = g_ptr_array_index(list->children, (guint)i);
        same = row->id && strcmp(row->id, pending.rows[i].id) == 0;
    }
    if (!same) {
        set_focused(NULL);
        clear_children(list);
        for (int i = 0; i < pending.count; i++) {
            AccessibleNode *row = new_component(ATK_ROLE_LIST_ITEM, pending.rows[i].name);
            row->id = g_strdup(pending.rows[i].id);
            atk_object_set_accessible_id(ATK_OBJECT(row), row->id);
            row->row = i;
            row->selected = pending.rows[i].selected;
            row->canOpen = pending.canOpen;
            row->bounds = pending.rows[i].bounds;
            add_child(list, row);
            g_object_unref(row);
        }
        generation++;
    } else {
        for (int i = 0; i < pending.count; i++) {
            AccessibleNode *row = g_ptr_array_index(list->children, (guint)i);
            set_name_if_changed(row, pending.rows[i].name);
            row->canOpen = pending.canOpen;
            row->bounds = pending.rows[i].bounds;
            if (row->selected != pending.rows[i].selected) {
                row->selected = pending.rows[i].selected;
                atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SELECTED, row->selected);
            }
        }
    }
    show_content(list);
    refresh_focus();
    set_terminal_text(NULL, 0, -1);
}
void tw_accessibility_show_terminal(TWWindow *window, const char *name) {
    (void)window;
    if (!bridgeReady) return;
    if (name)
        set_name_if_changed((AccessibleNode *)terminal, strnlen(name, 512) < 512 ? name : "[terminal title exceeds 512 bytes]");
    show_content((AccessibleNode *)terminal);
}
void tw_accessibility_terminal_text(TWWindow *window, const char *utf8, int length, int caret) {
    (void)window;
    if (!bridgeReady) return;
    set_terminal_text(utf8, length, caret);
}
#endif
