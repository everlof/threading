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
       MAX_TERMINAL_TEXT = 64 * 1024, MAX_TERMINAL_RUNS = 128 * 40 + 40 };
enum { PROJECT_CONTROL_NONE, PROJECT_CONTROL_CREATE, PROJECT_CONTROL_ACTIONS };

typedef struct {
    AtkObject parent;
    GPtrArray *children;
    char *id;
    AtkRectangle bounds;
    int row, selected, canOpen, retired, enabled, projectControl, actionRow;
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

typedef struct { ComponentNode parent; } ListNode;
typedef struct { ComponentNodeClass parent; } ListNodeClass;
static void selection_interface_init(AtkSelectionIface *iface);
G_DEFINE_TYPE_WITH_CODE(ListNode, list_node, component_node_get_type(),
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_SELECTION, selection_interface_init))

typedef struct {
    ComponentNode parent;
    char *text;
    int length, characters, caret;
    TWTextRun *runs;
    int runCount;
} TerminalNode;
typedef struct { ComponentNodeClass parent; } TerminalNodeClass;
static void text_interface_init(AtkTextIface *iface);
G_DEFINE_TYPE_WITH_CODE(TerminalNode, terminal_node, component_node_get_type(),
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_TEXT, text_interface_init))

static AccessibleNode *app, *frame, *list, *actionsButton, *addProjectButton, *pageTitleButton;
static AccessibleNode *placeholder, *placeholderTitle, *placeholderDetail, *placeholderAction;
static int actionsVisible, addProjectVisible, pageTitleVisible, placeholderVisible, placeholderActionVisible;
static char pageTitleIdentity[128];
static TerminalNode *terminal;
static AccessibleNode *activeList;
static AccessibleNode *focused;
static TWWindow *hostWindow;
static uint32_t eventType = UINT32_MAX, generation = 1;
static int bridgeReady, windowFocused;
static void navigation_trace_enqueue(const SDL_Event *event, int result) {
    static int enabled = -1;
    static unsigned records;
    if (enabled < 0) {
        const char *value = getenv("THREADING_LINUX_NAVIGATION_TRACE");
        enabled = value && strcmp(value, "1") == 0;
    }
    if (!enabled || records >= TW_MAX_NAVIGATION_TRACE_RECORDS) return;
    records++;
    fprintf(stderr, "NAVIGATION_TRACE scope=accessibility stage=enqueue monotonicMs=%.3f "
            "code=%d row=%d generation=%u pushResult=%d\n",
            (double)g_get_monotonic_time() / 1000, event->user.code,
            (int)(intptr_t)event->user.data1, (uint32_t)(uintptr_t)event->user.data2, result);
    fflush(stderr);
}
static struct {
    char title[128];
    int first, total, count, canOpen;
    AtkRectangle bounds;
    struct {
        char id[MAX_ROW_ID], name[MAX_ROW_NAME];
        int selected, enabled, hasProjectControls, controlsEnabled;
        AtkRectangle bounds, createBounds, actionsBounds;
    } rows[MAX_VISIBLE_ROWS];
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
    if (node->enabled) {
        atk_state_set_add_state(states, ATK_STATE_ENABLED);
        atk_state_set_add_state(states, ATK_STATE_SENSITIVE);
    }
    if (node == list || node == (AccessibleNode *)terminal || node == actionsButton ||
        node == addProjectButton || node == pageTitleButton || node == placeholderAction ||
        node->row >= 0 || node->projectControl) {
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
    node->actionRow = -1;
    node->enabled = 1;
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
        if (child->row >= 0) {
            child->retired = 1;
            for (guint i = 0; i < child->children->len; i++)
                ((AccessibleNode *)g_ptr_array_index(child->children, i))->retired = 1;
        }
        if (child->projectControl) child->retired = 1;
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
    if (windowFocused && frame && frame->children->len) {
        AccessibleNode *rightPane = placeholderVisible ? placeholder : (AccessibleNode *)terminal;
        AccessibleNode *content = tw_workspace_sidebar_width(hostWindow)
            ? (tw_workspace_sidebar_focused(hostWindow) ? list : rightPane)
            : g_ptr_array_index(frame->children, 0);
        if (content == list) {
            next = list;
            for (guint i = 0; i < list->children->len; i++) {
                AccessibleNode *row = g_ptr_array_index(list->children, i);
                if (row->selected) { next = row; break; }
            }
        } else if (content == (AccessibleNode *)terminal) next = content;
        else if (content == placeholder && placeholderActionVisible) next = placeholderAction;
    }
    set_focused(next);
}
static void show_content(AccessibleNode *content) {
    if (!frame) return;
    const int workspace = tw_workspace_sidebar_width(hostWindow) != 0;
    const int titleVisible = workspace && pageTitleVisible && !placeholderVisible;
    AccessibleNode *rightPane = placeholderVisible ? placeholder : (AccessibleNode *)terminal;
    const guint baseCount = workspace ? 2 + titleVisible : 1;
    const guint count = baseCount + actionsVisible + addProjectVisible;
    int same = frame->children->len == count
        && g_ptr_array_index(frame->children, 0) == (workspace ? list : content);
    if (same && titleVisible) same = g_ptr_array_index(frame->children, 1) == pageTitleButton;
    if (same && workspace) same = g_ptr_array_index(frame->children, 1 + titleVisible) == rightPane;
    if (same && actionsVisible) same = g_ptr_array_index(frame->children, baseCount) == actionsButton;
    if (same && addProjectVisible)
        same = g_ptr_array_index(frame->children, baseCount + actionsVisible) == addProjectButton;
    if (!same) {
        set_focused(NULL);
        clear_children(frame);
        add_child(frame, workspace ? list : content);
        if (titleVisible) add_child(frame, pageTitleButton);
        if (workspace) add_child(frame, rightPane);
        if (actionsVisible) add_child(frame, actionsButton);
        if (addProjectVisible) add_child(frame, addProjectButton);
        generation++;
    }
    activeList = workspace || content == list ? list : NULL;
    refresh_focus();
}

void tw_accessibility_workspace_changed(TWWindow *window) {
    if (!bridgeReady || window != hostWindow) return;
    show_content(tw_workspace_sidebar_width(window) && !tw_workspace_sidebar_focused(window)
                 ? (placeholderVisible ? placeholder : (AccessibleNode *)terminal) : list);
}
static AtkObject *get_root(void) { return ATK_OBJECT(app); }
static const gchar *get_toolkit_name(void) { return "Threading Linux bridge"; }
static const gchar *get_toolkit_version(void) { return "0"; }

static gint action_count(AtkAction *action) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (node == actionsButton) return actionsVisible && node->enabled ? 1 : 0;
    if (node == pageTitleButton) return pageTitleVisible && node->enabled &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == placeholderAction) return placeholderVisible && placeholderActionVisible &&
        node->enabled && node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == addProjectButton) return addProjectVisible && node->enabled &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node->projectControl) return !node->retired && node->enabled &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    return node->row < 0 ? 0 : (node->canOpen && node->enabled ? 2 : 1);
}
static const gchar *action_name(AtkAction *action, gint index) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (node == actionsButton || node == addProjectButton || node == pageTitleButton ||
        node == placeholderAction ||
        node->projectControl)
        return index == 0 && action_count(action) ? "press" : NULL;
    if (node->row < 0) return NULL;
    return index == 0 ? "select" : (index == 1 && node->canOpen && node->enabled ? "open" : NULL);
}
static gboolean action_do(AtkAction *action, gint index) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (node == pageTitleButton) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType; event.user.code = 7;
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node == placeholderAction) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType; event.user.code = 8;
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node == actionsButton) {
        if (index != 0 || !actionsVisible || !node->enabled || !node_mounted(ATK_OBJECT(node))
            || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType; event.user.code = 3;
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node == addProjectButton) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType; event.user.code = 5;
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node->projectControl) {
        if (index != 0 || !action_count(action) || !activeList ||
            node->actionRow < 0 || (guint)node->actionRow >= activeList->children->len ||
            eventType == UINT32_MAX) return FALSE;
        AccessibleNode *row = g_ptr_array_index(activeList->children, (guint)node->actionRow);
        const guint childIndex = node->projectControl == PROJECT_CONTROL_CREATE ? 0 : 1;
        if (row->retired || atk_object_get_parent(ATK_OBJECT(node)) != ATK_OBJECT(row) ||
            row->children->len != 2 || g_ptr_array_index(row->children, childIndex) != node)
            return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        event.user.code = node->projectControl == PROJECT_CONTROL_CREATE ? 6 : 4;
        event.user.data1 = (void *)(intptr_t)node->actionRow;
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (!activeList || node->row < 0 || (guint)node->row >= activeList->children->len
        || g_ptr_array_index(activeList->children, (guint)node->row) != node
        || index < 0 || index >= action_count(action) || eventType == UINT32_MAX) return FALSE;
    SDL_Event event = {0};
    event.type = eventType;
    event.user.code = 1;
    event.user.data1 = (void *)(intptr_t)node->row;
    event.user.data2 = (void *)(uintptr_t)generation;
    int pushed = SDL_PushEvent(&event);
    navigation_trace_enqueue(&event, pushed);
    if (pushed != 1) return FALSE;
    if (index == 1) {
        event.user.code = 2;
        pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        if (pushed != 1) return FALSE;
    }
    return TRUE;
}
static void action_interface_init(AtkActionIface *iface) {
    iface->get_n_actions = action_count;
    iface->get_name = action_name;
    iface->do_action = action_do;
}

static gint selected_row_index(void) {
    if (!list) return -1;
    for (guint i = 0; i < list->children->len; i++) {
        AccessibleNode *row = g_ptr_array_index(list->children, i);
        if (!row->retired && row->selected) return (gint)i;
    }
    return -1;
}
static gboolean list_select_child(AtkSelection *selection, gint index) {
    (void)selection;
    if (!list || activeList != list || index < 0 || (guint)index >= list->children->len) return FALSE;
    AccessibleNode *row = g_ptr_array_index(list->children, (guint)index);
    return row->selected || action_do(ATK_ACTION(row), 0);
}
static gboolean list_clear_selection(AtkSelection *selection) {
    (void)selection;
    return FALSE; // Navigation always has one selected row when the list is nonempty.
}
static AtkObject *list_ref_selection(AtkSelection *selection, gint index) {
    (void)selection;
    gint selected = selected_row_index();
    return index == 0 && selected >= 0 ? node_ref_child(ATK_OBJECT(list), selected) : NULL;
}
static gint list_selection_count(AtkSelection *selection) {
    (void)selection;
    return selected_row_index() >= 0 ? 1 : 0;
}
static gboolean list_child_selected(AtkSelection *selection, gint index) {
    (void)selection;
    if (!list || index < 0 || (guint)index >= list->children->len) return FALSE;
    AccessibleNode *row = g_ptr_array_index(list->children, (guint)index);
    return !row->retired && row->selected;
}
static gboolean list_remove_selection(AtkSelection *selection, gint index) {
    (void)selection; (void)index;
    return FALSE;
}
static gboolean list_select_all(AtkSelection *selection) {
    (void)selection;
    return FALSE; // The project and picker lists are single-selection.
}
static void selection_interface_init(AtkSelectionIface *iface) {
    iface->add_selection = list_select_child;
    iface->clear_selection = list_clear_selection;
    iface->ref_selection = list_ref_selection;
    iface->get_selection_count = list_selection_count;
    iface->is_child_selected = list_child_selected;
    iface->remove_selection = list_remove_selection;
    iface->select_all_selection = list_select_all;
}
static void list_node_class_init(ListNodeClass *klass) { (void)klass; }
static void list_node_init(ListNode *node) { (void)node; }

static int component_rectangle(AtkObject *object, AtkCoordType coordinates,
                               gint *x, gint *y, gint *width, gint *height) {
    AccessibleNode *node = (AccessibleNode *)object;
    if (!hostWindow || node->retired || !node_mounted(object)) return 0;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(hostWindow, &originX, &originY, &windowWidth, &windowHeight);
    if (object == ATK_OBJECT(frame)) {
        *x = 0; *y = 0; *width = windowWidth; *height = windowHeight;
    } else if (object == ATK_OBJECT(placeholder)) {
        *x = tw_workspace_sidebar_width(hostWindow); *y = 0;
        *width = windowWidth > *x ? windowWidth - *x : 0; *height = windowHeight;
    } else if (object == ATK_OBJECT(terminal)) {
        *x = tw_workspace_sidebar_width(hostWindow);
        *y = tw_workspace_terminal_top_inset_value(hostWindow);
        *width = windowWidth > *x ? windowWidth - *x : 0;
        *height = windowHeight > *y ? windowHeight - *y : 0;
    } else if (object == ATK_OBJECT(actionsButton) || object == ATK_OBJECT(addProjectButton) ||
               object == ATK_OBJECT(pageTitleButton) || object == ATK_OBJECT(placeholderAction)) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (object == ATK_OBJECT(list)) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (node->projectControl && node->actionRow >= 0 &&
               atk_object_get_parent(object) != NULL) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (node->row >= 0 && atk_object_get_parent(object) == ATK_OBJECT(list)) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else return 0;
    if (coordinates == ATK_XY_SCREEN) { *x += originX; *y += originY; }
    else if (coordinates == ATK_XY_PARENT && object == ATK_OBJECT(placeholderAction)) {
        *x -= tw_workspace_sidebar_width(hostWindow);
    }
    else if (coordinates == ATK_XY_PARENT && node->projectControl) {
        AccessibleNode *row = (AccessibleNode *)atk_object_get_parent(object);
        *x -= row->bounds.x; *y -= row->bounds.y;
    }
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
    // Convert the caller's point once, then compare children in window coordinates. A project
    // row is also a container: its Actions child uses row-relative parent coordinates.
    if (coordinates == ATK_XY_SCREEN) {
        int originX, originY, width, height;
        tw_window_geometry(hostWindow, &originX, &originY, &width, &height);
        x -= originX; y -= originY;
    } else if (coordinates == ATK_XY_PARENT) {
        int parentX, parentY, parentWidth, parentHeight;
        if (!component_rectangle(ATK_OBJECT(node), ATK_XY_WINDOW,
                                 &parentX, &parentY, &parentWidth, &parentHeight)) return NULL;
        x += parentX; y += parentY;
    } else if (coordinates != ATK_XY_WINDOW) return NULL;
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
static void terminal_character_extents(AtkText *text, gint offset, gint *x, gint *y,
                                       gint *width, gint *height, AtkCoordType coordinates) {
    TerminalNode *node = (TerminalNode *)text;
    int resultX = -1, resultY = -1, resultWidth = -1, resultHeight = -1;
    if (hostWindow && node_mounted(ATK_OBJECT(node)) && offset >= 0 &&
        offset < node->characters && node->runCount > 0 &&
        (coordinates == ATK_XY_WINDOW || coordinates == ATK_XY_SCREEN || coordinates == ATK_XY_PARENT)) {
        int low = 0, high = node->runCount;
        while (low < high) {
            int middle = low + (high - low) / 2;
            if (node->runs[middle].offset + node->runs[middle].characters <= offset) low = middle + 1;
            else high = middle;
        }
        if (low < node->runCount && node->runs[low].offset <= offset) {
            TWTextRun run = node->runs[low];
            resultX = run.column * TW_TERMINAL_CELL_WIDTH;
            resultY = run.row * TW_TERMINAL_CELL_HEIGHT;
            resultWidth = run.cells * TW_TERMINAL_CELL_WIDTH;
            resultHeight = TW_TERMINAL_CELL_HEIGHT;
            if (coordinates != ATK_XY_PARENT) {
                resultX += tw_workspace_sidebar_width(hostWindow);
                resultY += tw_workspace_terminal_top_inset_value(hostWindow);
            }
            if (coordinates == ATK_XY_SCREEN) {
                int originX, originY, windowWidth, windowHeight;
                tw_window_geometry(hostWindow, &originX, &originY, &windowWidth, &windowHeight);
                resultX += originX; resultY += originY;
            }
        }
    }
    if (x) *x = resultX;
    if (y) *y = resultY;
    if (width) *width = resultWidth;
    if (height) *height = resultHeight;
}
static gint terminal_offset_at_point(AtkText *text, gint x, gint y, AtkCoordType coordinates) {
    TerminalNode *node = (TerminalNode *)text;
    if (!hostWindow || !node_mounted(ATK_OBJECT(node)) || node->runCount == 0) return -1;
    if (coordinates == ATK_XY_SCREEN) {
        int originX, originY, windowWidth, windowHeight;
        tw_window_geometry(hostWindow, &originX, &originY, &windowWidth, &windowHeight);
        x -= originX; y -= originY;
    } else if (coordinates != ATK_XY_WINDOW && coordinates != ATK_XY_PARENT) return -1;
    int terminalX, terminalY, terminalWidth, terminalHeight;
    if (!component_rectangle(ATK_OBJECT(node), ATK_XY_WINDOW,
                             &terminalX, &terminalY, &terminalWidth, &terminalHeight)) return -1;
    if (coordinates == ATK_XY_PARENT) {
        x += terminalX;
        y += terminalY;
    }
    if (x < terminalX || x >= terminalX + terminalWidth ||
        y < terminalY || y >= terminalY + terminalHeight) return -1;
    x -= terminalX; y -= terminalY;
    if (x < 0 || y < 0 || y / TW_TERMINAL_CELL_HEIGHT >= 40) return -1;
    int row = y / TW_TERMINAL_CELL_HEIGHT;
    int low = 0, high = node->runCount;
    while (low < high) {
        int middle = low + (high - low) / 2;
        if (node->runs[middle].row < row) low = middle + 1;
        else high = middle;
    }
    for (int i = low; i < node->runCount && node->runs[i].row == row; i++) {
        TWTextRun run = node->runs[i];
        int left = run.column * TW_TERMINAL_CELL_WIDTH;
        if (run.cells > 0 && x >= left && x < left + run.cells * TW_TERMINAL_CELL_WIDTH)
            return run.offset;
    }
    return -1;
}
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
    iface->get_character_extents = terminal_character_extents;
    iface->get_offset_at_point = terminal_offset_at_point;
    iface->get_string_at_offset = terminal_string_at;
}
static void terminal_node_finalize(GObject *object) {
    g_free(((TerminalNode *)object)->text);
    g_free(((TerminalNode *)object)->runs);
    G_OBJECT_CLASS(terminal_node_parent_class)->finalize(object);
}
static void terminal_node_class_init(TerminalNodeClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = terminal_node_finalize;
}
static void terminal_node_init(TerminalNode *node) {
    node->text = g_strdup("");
    node->caret = -1;
}
static void set_terminal_text(const char *value, int length, int caret,
                              const TWTextRun *runs, int runCount) {
    if (!terminal) return;
    if (!value) { value = ""; length = 0; caret = -1; runs = NULL; runCount = 0; }
    if (length < 0 || length > MAX_TERMINAL_TEXT ||
        memchr(value, 0, (size_t)length) || !g_utf8_validate(value, length, NULL) ||
        runCount < 0 || runCount > MAX_TERMINAL_RUNS || (runCount && !runs)) return;
    int characters = (int)g_utf8_strlen(value, length);
    if (caret < -1 || caret > characters) caret = -1;
    // Runs are ordered by displayed row and cover each Unicode scalar exactly once. The
    // overflow notice intentionally has no geometry: it is not a rendered terminal cell.
    int nextOffset = 0, previousRow = -1, previousColumn = -1;
    for (int i = 0; i < runCount; i++) {
        TWTextRun run = runs[i];
        if (run.offset != nextOffset || run.characters <= 0 || run.characters > characters - nextOffset ||
            run.row < 0 || run.row >= 40 || run.column < 0 || run.column > 128 ||
            run.cells < 0 || run.cells > 2 || run.column + run.cells > 128 ||
            run.row < previousRow || (run.row == previousRow && run.column < previousColumn)) return;
        nextOffset += run.characters;
        previousRow = run.row; previousColumn = run.column;
    }
    if (runCount && nextOffset != characters) return;
    TWTextRun *newRuns = runCount ? g_memdup2(runs, (size_t)runCount * sizeof(*runs)) : NULL;
    g_free(terminal->runs);
    terminal->runs = newRuns;
    terminal->runCount = runCount;
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
    list = g_object_new(list_node_get_type(), NULL);
    atk_object_set_role(ATK_OBJECT(list), ATK_ROLE_LIST);
    atk_object_set_name(ATK_OBJECT(list), "Projects");
    actionsButton = new_component(ATK_ROLE_PUSH_BUTTON, "Actions");
    actionsButton->id = g_strdup("linux.actions");
    atk_object_set_accessible_id(ATK_OBJECT(actionsButton), actionsButton->id);
    addProjectButton = new_component(ATK_ROLE_PUSH_BUTTON, "Add Project");
    addProjectButton->id = g_strdup("linux.add-project");
    atk_object_set_accessible_id(ATK_OBJECT(addProjectButton), addProjectButton->id);
    pageTitleButton = new_component(ATK_ROLE_PUSH_BUTTON, "Page title");
    pageTitleButton->id = g_strdup("linux.page-title");
    atk_object_set_accessible_id(ATK_OBJECT(pageTitleButton), pageTitleButton->id);
    placeholder = new_component(ATK_ROLE_PANEL, "Session placeholder");
    placeholderTitle = new_node(ATK_ROLE_LABEL, "");
    placeholderDetail = new_node(ATK_ROLE_LABEL, "");
    placeholderAction = new_component(ATK_ROLE_PUSH_BUTTON, "New Session");
    placeholderAction->id = g_strdup("linux.placeholder.action");
    atk_object_set_accessible_id(ATK_OBJECT(placeholderAction), placeholderAction->id);
    actionsVisible = 0;
    addProjectVisible = 0;
    pageTitleVisible = 0;
    placeholderVisible = placeholderActionVisible = 0;
    pageTitleIdentity[0] = '\0';
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
    g_clear_object(&actionsButton);
    g_clear_object(&addProjectButton);
    g_clear_object(&pageTitleButton);
    g_clear_object(&placeholder);
    g_clear_object(&placeholderTitle);
    g_clear_object(&placeholderDetail);
    g_clear_object(&placeholderAction);
    actionsVisible = addProjectVisible = pageTitleVisible = 0;
    placeholderVisible = placeholderActionVisible = 0;
    pageTitleIdentity[0] = '\0';
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
int tw_accessibility_row_can_open(int row) {
    if (!bridgeReady || !activeList || row < 0 || (guint)row >= activeList->children->len) return 0;
    AccessibleNode *node = g_ptr_array_index(activeList->children, (guint)row);
    return !node->retired && node->enabled && node->canOpen;
}
static int project_control_identity(int row, int control, char *id, int capacity) {
    if (!bridgeReady || !activeList || !id || capacity < MAX_ROW_ID || row < 0 ||
        (guint)row >= activeList->children->len) return 0;
    AccessibleNode *item = g_ptr_array_index(activeList->children, (guint)row);
    if (item->retired || !item->id || item->children->len != 2) return 0;
    const guint childIndex = control == PROJECT_CONTROL_CREATE ? 0 : 1;
    AccessibleNode *button = g_ptr_array_index(item->children, childIndex);
    if (button->projectControl != control || button->retired || !button->enabled ||
        button->actionRow != row || !node_mounted(ATK_OBJECT(button))) return 0;
    strcpy(id, item->id); // The row API already bounded this ID to MAX_ROW_ID - 1 bytes.
    return 1;
}
int tw_accessibility_project_action_identity(int row, char *id, int capacity) {
    return project_control_identity(row, PROJECT_CONTROL_ACTIONS, id, capacity);
}
int tw_accessibility_project_create_identity(int row, char *id, int capacity) {
    return project_control_identity(row, PROJECT_CONTROL_CREATE, id, capacity);
}
void tw_accessibility_actions_button(TWWindow *window, const char *label, int enabled,
                                     int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow) return;
    const int visible = height > 0;
    if (actionsVisible != visible || actionsButton->enabled != (enabled != 0)) generation++;
    actionsVisible = visible;
    if (label && strnlen(label, 64) < 64 && g_utf8_validate(label, -1, NULL))
        set_name_if_changed(actionsButton, label);
    if (actionsButton->enabled != (enabled != 0)) {
        actionsButton->enabled = enabled != 0;
        atk_object_notify_state_change(ATK_OBJECT(actionsButton), ATK_STATE_ENABLED, actionsButton->enabled);
        atk_object_notify_state_change(ATK_OBJECT(actionsButton), ATK_STATE_SENSITIVE, actionsButton->enabled);
    }
    actionsButton->bounds = (AtkRectangle){x, y, width, height};
    show_content(activeList ? list : (AccessibleNode *)terminal);
}
void tw_accessibility_add_project_button(TWWindow *window, int enabled,
                                         int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow) return;
    const int visible = height > 0;
    if (addProjectVisible != visible || addProjectButton->enabled != (enabled != 0)) generation++;
    addProjectVisible = visible;
    if (addProjectButton->enabled != (enabled != 0)) {
        addProjectButton->enabled = enabled != 0;
        atk_object_notify_state_change(ATK_OBJECT(addProjectButton), ATK_STATE_ENABLED,
                                       addProjectButton->enabled);
        atk_object_notify_state_change(ATK_OBJECT(addProjectButton), ATK_STATE_SENSITIVE,
                                       addProjectButton->enabled);
    }
    addProjectButton->bounds = (AtkRectangle){x, y, width, height};
    show_content(activeList ? list : (AccessibleNode *)terminal);
}
void tw_accessibility_page_title(TWWindow *window, const char *identity, const char *name,
                                 int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow) return;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    const int sidebarWidth = tw_workspace_sidebar_width(window);
    const int topInset = tw_workspace_terminal_top_inset_value(window);
    const int visible = sidebarWidth > 0 && identity && name &&
        strnlen(identity, sizeof(pageTitleIdentity)) < sizeof(pageTitleIdentity) &&
        strnlen(name, 512) < 512 && g_utf8_validate(name, -1, NULL) &&
        x >= sidebarWidth && x < windowWidth && width > 0 && width <= windowWidth - x &&
        y >= 0 && y < topInset && height > 0 && height <= topInset - y;
    if (pageTitleVisible != visible ||
        (visible && strcmp(pageTitleIdentity, identity) != 0)) generation++;
    pageTitleVisible = visible;
    if (visible) {
        g_strlcpy(pageTitleIdentity, identity, sizeof(pageTitleIdentity));
        set_name_if_changed(pageTitleButton, name);
        pageTitleButton->bounds = (AtkRectangle){x, y, width, height};
    } else pageTitleIdentity[0] = '\0';
    show_content(activeList ? list : (AccessibleNode *)terminal);
}
void tw_accessibility_placeholder(TWWindow *window, const char *title, const char *detail,
                                   const char *actionLabel, int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow) return;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    const int sidebarWidth = tw_workspace_sidebar_width(window);
    const int visible = sidebarWidth > 0 && title && detail &&
        strnlen(title, 512) < 512 && strnlen(detail, 512) < 512 &&
        g_utf8_validate(title, -1, NULL) && g_utf8_validate(detail, -1, NULL);
    const int actionVisible = visible && actionLabel &&
        strnlen(actionLabel, 512) < 512 && g_utf8_validate(actionLabel, -1, NULL) &&
        x >= sidebarWidth && x < windowWidth && width > 0 && width <= windowWidth - x &&
        y >= 0 && y < windowHeight && height > 0 && height <= windowHeight - y;
    if (placeholderVisible != visible || placeholderActionVisible != actionVisible) generation++;
    placeholderVisible = visible;
    placeholderActionVisible = actionVisible;
    if (visible) {
        if (strcmp(atk_object_get_name(ATK_OBJECT(placeholderTitle)), title) != 0 ||
            strcmp(atk_object_get_name(ATK_OBJECT(placeholderDetail)), detail) != 0 ||
            (actionVisible && strcmp(atk_object_get_name(ATK_OBJECT(placeholderAction)), actionLabel) != 0))
            generation++;
        set_name_if_changed(placeholderTitle, title);
        set_name_if_changed(placeholderDetail, detail);
        if (actionVisible) {
            set_name_if_changed(placeholderAction, actionLabel);
            placeholderAction->bounds = (AtkRectangle){x, y, width, height};
        }
    }
    const int detailVisible = visible && detail[0] != '\0';
    const guint expected = visible ? 1 + detailVisible + actionVisible : 0;
    int same = placeholder->children->len == expected;
    if (same && expected) same = g_ptr_array_index(placeholder->children, 0) == placeholderTitle;
    if (same && detailVisible)
        same = g_ptr_array_index(placeholder->children, 1) == placeholderDetail;
    if (same && actionVisible)
        same = g_ptr_array_index(placeholder->children, expected - 1) == placeholderAction;
    if (!same) {
        if (focused == placeholderAction) set_focused(NULL);
        clear_children(placeholder);
        if (visible) {
            add_child(placeholder, placeholderTitle);
            if (detailVisible) add_child(placeholder, placeholderDetail);
            if (actionVisible) add_child(placeholder, placeholderAction);
        }
        generation++;
    }
    show_content(activeList ? list : (placeholderVisible ? placeholder : (AccessibleNode *)terminal));
    refresh_focus();
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
    if (tw_workspace_sidebar_width(window)) windowWidth = tw_workspace_sidebar_width(window);
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
    pending.rows[index].enabled = 1;
    pending.rows[index].hasProjectControls = 0;
    pending.rows[index].controlsEnabled = 0;
    pending.rows[index].bounds = (AtkRectangle){x, y, width, height};
    return 0;
}
int tw_accessibility_add_project_row(TWWindow *window, const char *id, const char *name, int selected,
                                     int x, int y, int width, int height,
                                     int createX, int createY, int createWidth, int createHeight,
                                     int actionsX, int actionsY, int actionsWidth, int actionsHeight,
                                     int controlsEnabled) {
    const int index = pending.count;
    if (tw_accessibility_add_row(window, id, name, selected, x, y, width, height) != 0) return -1;
    if (!bridgeReady) return 0;
    if (pending.count != index + 1 ||
        createWidth <= 0 || createHeight <= 0 ||
        createX < x || createY < y || createX >= x + width || createY >= y + height ||
        createWidth > x + width - createX || createHeight > y + height - createY ||
        actionsWidth <= 0 || actionsHeight <= 0 ||
        actionsX < x || actionsY < y || actionsX >= x + width || actionsY >= y + height ||
        actionsWidth > x + width - actionsX || actionsHeight > y + height - actionsY ||
        createX + createWidth > actionsX) {
        pending.count = index;
        return -1;
    }
    pending.rows[index].hasProjectControls = 1;
    pending.rows[index].controlsEnabled = controlsEnabled != 0;
    pending.rows[index].createBounds = (AtkRectangle){createX, createY, createWidth, createHeight};
    pending.rows[index].actionsBounds = (AtkRectangle){actionsX, actionsY, actionsWidth, actionsHeight};
    return 0;
}
int tw_accessibility_add_action_row(TWWindow *window, const char *id, const char *name, int selected,
                                    int enabled, int x, int y, int width, int height) {
    const int index = pending.count;
    int result = tw_accessibility_add_row(window, id, name, selected, x, y, width, height);
    if (result == 0 && bridgeReady && pending.count == index + 1) pending.rows[index].enabled = enabled != 0;
    return result;
}
static void add_project_control(AccessibleNode *row, int slot, int control, int enabled,
                                AtkRectangle bounds) {
    AccessibleNode *button = new_component(ATK_ROLE_PUSH_BUTTON,
        control == PROJECT_CONTROL_CREATE ? "New chat or terminal" : "Project actions");
    // Row IDs are bounded to 63 bytes by add_row. The child IDs survive reorder and name
    // the same control as the production ProjectRowView's two trailing buttons.
    button->id = g_strdup_printf("sidebar.project.%s.%s",
                                 control == PROJECT_CONTROL_CREATE ? "create" : "actions", row->id);
    atk_object_set_accessible_id(ATK_OBJECT(button), button->id);
    button->projectControl = control;
    button->actionRow = slot;
    button->enabled = enabled;
    button->bounds = bounds;
    add_child(row, button);
    g_object_unref(button);
}
static void add_project_controls(AccessibleNode *row, int slot, int enabled,
                                 AtkRectangle createBounds, AtkRectangle actionsBounds) {
    add_project_control(row, slot, PROJECT_CONTROL_CREATE, enabled, createBounds);
    add_project_control(row, slot, PROJECT_CONTROL_ACTIONS, enabled, actionsBounds);
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
    int selectionChanged = !same;
    if (!same) {
        if (focused != (AccessibleNode *)terminal) set_focused(NULL);
        clear_children(list);
        for (int i = 0; i < pending.count; i++) {
            AccessibleNode *row = new_component(ATK_ROLE_LIST_ITEM, pending.rows[i].name);
            row->id = g_strdup(pending.rows[i].id);
            atk_object_set_accessible_id(ATK_OBJECT(row), row->id);
            row->row = i;
            row->selected = pending.rows[i].selected;
            row->canOpen = pending.canOpen;
            row->enabled = pending.rows[i].enabled;
            row->bounds = pending.rows[i].bounds;
            add_child(list, row);
            if (pending.rows[i].hasProjectControls)
                add_project_controls(row, i, pending.rows[i].controlsEnabled,
                                     pending.rows[i].createBounds, pending.rows[i].actionsBounds);
            g_object_unref(row);
        }
        generation++;
    } else {
        for (int i = 0; i < pending.count; i++) {
            AccessibleNode *row = g_ptr_array_index(list->children, (guint)i);
            set_name_if_changed(row, pending.rows[i].name);
            if (row->enabled != pending.rows[i].enabled || row->canOpen != pending.canOpen) generation++;
            row->canOpen = pending.canOpen;
            if (row->enabled != pending.rows[i].enabled) {
                row->enabled = pending.rows[i].enabled;
                atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_ENABLED, row->enabled);
                atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SENSITIVE, row->enabled);
            }
            row->bounds = pending.rows[i].bounds;
            const int hadProjectControls = row->children->len != 0;
            if (hadProjectControls != pending.rows[i].hasProjectControls) {
                clear_children(row);
                if (pending.rows[i].hasProjectControls)
                    add_project_controls(row, i, pending.rows[i].controlsEnabled,
                                         pending.rows[i].createBounds, pending.rows[i].actionsBounds);
                generation++;
            } else if (hadProjectControls) {
                for (guint child = 0; child < 2; child++) {
                    AccessibleNode *button = g_ptr_array_index(row->children, child);
                    if (button->enabled != pending.rows[i].controlsEnabled) {
                        button->enabled = pending.rows[i].controlsEnabled;
                        generation++;
                        atk_object_notify_state_change(ATK_OBJECT(button), ATK_STATE_ENABLED, button->enabled);
                        atk_object_notify_state_change(ATK_OBJECT(button), ATK_STATE_SENSITIVE, button->enabled);
                    }
                    button->bounds = child == 0 ? pending.rows[i].createBounds
                                                : pending.rows[i].actionsBounds;
                }
            }
            if (row->selected != pending.rows[i].selected) {
                row->selected = pending.rows[i].selected;
                atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SELECTED, row->selected);
                selectionChanged = 1;
            }
        }
    }
    show_content(list);
    refresh_focus();
    if (selectionChanged) g_signal_emit_by_name(list, "selection-changed");
    if (!tw_workspace_sidebar_width(hostWindow)) set_terminal_text(NULL, 0, -1, NULL, 0);
}
void tw_accessibility_show_terminal(TWWindow *window, const char *name) {
    (void)window;
    if (!bridgeReady) return;
    if (name)
        set_name_if_changed((AccessibleNode *)terminal, strnlen(name, 512) < 512 ? name : "[terminal title exceeds 512 bytes]");
    show_content((AccessibleNode *)terminal);
}
void tw_accessibility_terminal_text(TWWindow *window, const char *utf8, int length, int caret,
                                    const TWTextRun *runs, int runCount) {
    (void)window;
    if (!bridgeReady) return;
    set_terminal_text(utf8, length, caret, runs, runCount);
}
#endif
