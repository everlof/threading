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

enum { MAX_VISIBLE_ROWS = 32, MAX_ROW_NAME = 512, MAX_ROW_ID = 64 };

typedef struct {
    AtkObject parent;
    GPtrArray *children;
    char *id;
    int row, selected, canOpen, retired;
} AccessibleNode;
typedef struct { AtkObjectClass parent; } AccessibleNodeClass;

static void action_interface_init(AtkActionIface *iface);
G_DEFINE_TYPE_WITH_CODE(AccessibleNode, accessible_node, ATK_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_ACTION, action_interface_init))

static AccessibleNode *app, *frame, *list, *terminal;
static AccessibleNode *activeList;
static uint32_t eventType = UINT32_MAX, generation = 1;
static int bridgeReady;
static struct {
    char title[128];
    int first, total, count, canOpen;
    struct { char id[MAX_ROW_ID], name[MAX_ROW_NAME]; int selected; } rows[MAX_VISIBLE_ROWS];
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
static void show_content(AccessibleNode *content) {
    if (!frame || (frame->children->len == 1 && g_ptr_array_index(frame->children, 0) == content)) return;
    clear_children(frame);
    add_child(frame, content);
    activeList = content == list ? list : NULL;
    generation++;
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

void tw_accessibility_open(void) {
    if (!getenv("DBUS_SESSION_BUS_ADDRESS") || bridgeReady) return;
    eventType = SDL_RegisterEvents(1);
    app = new_node(ATK_ROLE_APPLICATION, "Threading Linux");
    frame = new_node(ATK_ROLE_FRAME, "Threading Linux window");
    list = new_node(ATK_ROLE_LIST, "Projects");
    terminal = new_node(ATK_ROLE_TERMINAL, "Terminal");
    atk_object_set_description(ATK_OBJECT(terminal),
        "Terminal text is not yet exposed to assistive technology.");
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
    if (bridgeReady) atk_bridge_adaptor_cleanup();
    bridgeReady = 0; activeList = NULL; eventType = UINT32_MAX;
    clear_children(list);
    clear_children(frame);
    clear_children(app);
    g_clear_object(&app);
    g_clear_object(&frame);
    g_clear_object(&list);
    g_clear_object(&terminal);
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

void tw_accessibility_begin_list(TWWindow *window, const char *name, int first, int total, int canOpen) {
    (void)window;
    if (!bridgeReady) return;
    pending.count = 0;
    pending.first = first;
    pending.total = total;
    pending.canOpen = canOpen;
    g_strlcpy(pending.title, name ? name : "Items", sizeof(pending.title));
}
int tw_accessibility_add_row(TWWindow *window, const char *id, const char *name, int selected) {
    (void)window;
    if (!bridgeReady) return 0;
    if (!id || !name || pending.count >= MAX_VISIBLE_ROWS
        || strnlen(id, MAX_ROW_ID) == MAX_ROW_ID
        || strnlen(name, MAX_ROW_NAME) == MAX_ROW_NAME
        || !g_utf8_validate(name, -1, NULL)) return -1;
    int index = pending.count++;
    strcpy(pending.rows[index].id, id);
    strcpy(pending.rows[index].name, name);
    pending.rows[index].selected = selected != 0;
    return 0;
}
void tw_accessibility_end_list(TWWindow *window) {
    (void)window;
    if (!bridgeReady) return;
    set_name_if_changed(list, pending.title);
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
        clear_children(list);
        for (int i = 0; i < pending.count; i++) {
            AccessibleNode *row = new_node(ATK_ROLE_LIST_ITEM, pending.rows[i].name);
            row->id = g_strdup(pending.rows[i].id);
            atk_object_set_accessible_id(ATK_OBJECT(row), row->id);
            row->row = i;
            row->selected = pending.rows[i].selected;
            row->canOpen = pending.canOpen;
            add_child(list, row);
            g_object_unref(row);
        }
        generation++;
    } else {
        for (int i = 0; i < pending.count; i++) {
            AccessibleNode *row = g_ptr_array_index(list->children, (guint)i);
            set_name_if_changed(row, pending.rows[i].name);
            row->canOpen = pending.canOpen;
            if (row->selected != pending.rows[i].selected) {
                row->selected = pending.rows[i].selected;
                atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SELECTED, row->selected);
            }
        }
    }
    show_content(list);
}
void tw_accessibility_show_terminal(TWWindow *window, const char *name) {
    (void)window;
    if (!bridgeReady) return;
    if (name)
        set_name_if_changed(terminal, strnlen(name, 512) < 512 ? name : "[terminal title exceeds 512 bytes]");
    show_content(terminal);
}
#endif
