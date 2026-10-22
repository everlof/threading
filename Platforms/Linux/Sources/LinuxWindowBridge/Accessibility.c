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
       MAX_TERMINAL_TEXT = 64 * 1024, MAX_TERMINAL_RUNS = 128 * 40 + 40,
       MAX_SESSION_MENU_ROWS = 8, MAX_COMPOSER_MENU_ROWS = 128,
       MAX_ATTACHMENT_TILES = 32, MAX_ATTACHMENT_NAME = 256,
       MAX_COMPOSER_TEXT = 64 * 1024,
       MAX_COMPOSER_EDITS = 16, MAX_COMPOSER_ID = 128 };
enum { PROJECT_CONTROL_NONE, PROJECT_CONTROL_CREATE, PROJECT_CONTROL_ACTIONS };

typedef struct {
    AtkObject parent;
    GPtrArray *children;
    char *id;
    char *controlTargetID;
    AtkRectangle bounds;
    int row, optionIndex, selected, highlighted, canOpen, retired, enabled, projectControl, actionRow;
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

typedef struct {
    ComponentNode parent;
    char *text;
    int length, characters, selectionStart, selectionEnd;
} ComposerEditorNode;
typedef struct { ComponentNodeClass parent; } ComposerEditorNodeClass;
static void composer_text_interface_init(AtkTextIface *iface);
static void composer_editable_interface_init(AtkEditableTextIface *iface);
G_DEFINE_TYPE_WITH_CODE(ComposerEditorNode, composer_editor_node, component_node_get_type(),
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_TEXT, composer_text_interface_init)
                        G_IMPLEMENT_INTERFACE(ATK_TYPE_EDITABLE_TEXT, composer_editable_interface_init))

static AccessibleNode *app, *frame, *list, *actionsButton, *addProjectButton, *settingsButton, *pageTitleButton;
static AccessibleNode *pageActionsButton, *openInPrimaryButton, *openInChooserButton;
static AccessibleNode *sessionMenuList;
static AccessibleNode *placeholder, *placeholderTitle, *placeholderDetail, *placeholderAction;
static AccessibleNode *promptPanel, *promptTitle, *promptMessage, *promptCancel, *promptCreate, *promptClear, *promptSuppression;
static int promptVisible, promptFocusKind;
static AccessibleNode *composerProjectChip, *composerProviderChip, *composerPermissionChip, *composerModelChip, *composerSurfaceChip, *composerSpeedChip, *composerMenuList;
static AccessibleNode *conversationSpeedChip, *conversationSpeedMenu;
static int conversationSpeedVisible, conversationSpeedMenuVisible, conversationSpeedFocused;
static char conversationSpeedIdentity[MAX_COMPOSER_ID];
static AccessibleNode *conversationContextLabel;
static char conversationContextIdentity[MAX_COMPOSER_ID];
static int conversationContextVisible;
static AccessibleNode *conversationConfigurationChips[3], *conversationConfigurationMenu;
static AccessibleNode *attachmentList;
static int attachmentScope;
static char attachmentOwner[MAX_COMPOSER_ID];
static int conversationConfigurationVisible[3], conversationConfigurationFocused[3];
static int conversationConfigurationMenuKind, conversationConfigurationFirst;
static char conversationConfigurationIdentity[MAX_COMPOSER_ID];
static int actionsVisible, addProjectVisible, settingsVisible, pageTitleVisible, placeholderVisible, placeholderActionVisible;
static int composerChipVisible[6], composerMenuVisible, composerMenuKind;
static ComposerEditorNode *composerEditor;
static int composerEditorVisible, composerEditorFocused, composerFocusKind = -1;
typedef struct {
    uint32_t serial, incarnation;
    int operation, start, end, length;
    char identity[MAX_COMPOSER_ID];
    char *text;
} ComposerEdit;
static GQueue *composerEdits;
static char composerIdentity[MAX_COMPOSER_ID];
static char composerMenuIdentity[MAX_COMPOSER_ID];
static uint32_t composerIncarnation = 1, composerEditSerial;
static int composerPredictedCharacters, composerPredictionValid;
static int pageActionsVisible, openInVisible, sessionMenuVisible;
static char pageTitleIdentity[128];
static char pageActionsIdentity[128], openInIdentity[128], sessionMenuIdentity[128];
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
        char id[MAX_ROW_ID], controlTargetID[MAX_ROW_ID], name[MAX_ROW_NAME];
        int selected, enabled, hasProjectControls, controlsEnabled;
        AtkRectangle bounds, createBounds, actionsBounds;
    } rows[MAX_VISIBLE_ROWS];
} pending;
static struct {
    char identity[128];
    char label[128];
    int visible, count;
    AtkRectangle bounds;
    struct {
        char id[MAX_ROW_ID], name[MAX_ROW_NAME];
        int selected, enabled;
        AtkRectangle bounds;
    } rows[MAX_SESSION_MENU_ROWS];
} sessionMenuPending;
static struct {
    char identity[MAX_COMPOSER_ID];
    int visible, kind, count;
    AtkRectangle bounds;
    struct {
        char id[MAX_ROW_ID], name[MAX_ROW_NAME], description[MAX_ROW_NAME];
        int optionIndex, selected, enabled, highlighted;
        AtkRectangle bounds;
    } rows[MAX_COMPOSER_MENU_ROWS];
} composerMenuPending;
static struct {
    int scope, count;
    char owner[MAX_COMPOSER_ID];
    struct {
        char id[37], name[MAX_ATTACHMENT_NAME];
        AtkRectangle bounds, removeBounds;
    } tiles[MAX_ATTACHMENT_TILES];
} attachmentPending;
static int composer_bounds_valid(TWWindow *window, int x, int y, int width, int height);
static int composer_identity_valid(const char *identity);
static void rebuild_placeholder_children(void);

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
static int composer_chip_kind(AccessibleNode *node);
static AccessibleNode *composer_chip(int kind);
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
    if (node == list || node == sessionMenuList || node == composerMenuList ||
        node == conversationSpeedChip || node == conversationSpeedMenu ||
        node == conversationConfigurationChips[0] || node == conversationConfigurationChips[1] ||
        node == conversationConfigurationChips[2] ||
        node == conversationConfigurationMenu ||
        composer_chip_kind(node) != 0 ||
        node == (AccessibleNode *)terminal ||
        node == (AccessibleNode *)composerEditor ||
        node == actionsButton || node == addProjectButton || node == settingsButton ||
        node == pageTitleButton ||
        node == pageActionsButton || node == openInPrimaryButton ||
        node == openInChooserButton || node == placeholderAction ||
        node == promptCancel || node == promptCreate || node == promptClear ||
        node == promptSuppression ||
        node->row >= 0 || node->projectControl) {
        atk_state_set_add_state(states, ATK_STATE_FOCUSABLE);
        if (node == focused) atk_state_set_add_state(states, ATK_STATE_FOCUSED);
    }
    if (node == (AccessibleNode *)composerEditor && composerEditorVisible && node_mounted(object)) {
        atk_state_set_add_state(states, ATK_STATE_EDITABLE);
        if (!promptVisible) atk_state_set_add_state(states, ATK_STATE_MULTI_LINE);
    }
    if (node == promptSuppression && node->selected)
        atk_state_set_add_state(states, ATK_STATE_CHECKED);
    if (node == conversationSpeedChip) {
        atk_state_set_add_state(states, ATK_STATE_EXPANDABLE);
        if (conversationSpeedMenuVisible) atk_state_set_add_state(states, ATK_STATE_EXPANDED);
    }
    for (int kind = 0; kind < 3; kind++) if (node == conversationConfigurationChips[kind]) {
        atk_state_set_add_state(states, ATK_STATE_EXPANDABLE);
        if (conversationConfigurationMenuKind == kind + 1)
            atk_state_set_add_state(states, ATK_STATE_EXPANDED);
    }
    if (composer_chip_kind(node) != 0) {
        atk_state_set_add_state(states, ATK_STATE_EXPANDABLE);
        if (composerMenuVisible && composerMenuKind == (composer_chip_kind(node)))
            atk_state_set_add_state(states, ATK_STATE_EXPANDED);
    }
    if (node_mounted(object)) {
        atk_state_set_add_state(states, ATK_STATE_VISIBLE);
        atk_state_set_add_state(states, ATK_STATE_SHOWING);
    }
    if (node->row >= 0 && atk_object_get_role(object) != ATK_ROLE_PUSH_BUTTON) {
        atk_state_set_add_state(states, ATK_STATE_SELECTABLE);
        if (node->selected) {
            atk_state_set_add_state(states, ATK_STATE_SELECTED);
            if (atk_object_get_role(object) == ATK_ROLE_RADIO_BUTTON)
                atk_state_set_add_state(states, ATK_STATE_CHECKED);
        }
    }
    return states;
}
static void node_finalize(GObject *object) {
    AccessibleNode *node = (AccessibleNode *)object;
    g_ptr_array_unref(node->children);
    g_free(node->id);
    g_free(node->controlTargetID);
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
    node->optionIndex = -1;
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
static void remove_child(AccessibleNode *parent, AccessibleNode *child) {
    for (guint index = 0; index < parent->children->len; index++) {
        if (g_ptr_array_index(parent->children, index) != child) continue;
        g_signal_emit_by_name(parent, "children-changed::remove", index, child);
        atk_object_set_parent(ATK_OBJECT(child), NULL);
        g_ptr_array_remove_index(parent->children, index);
        return;
    }
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
    if (windowFocused && promptVisible && promptPanel &&
        node_mounted(ATK_OBJECT(promptPanel))) {
        next = promptFocusKind == 1 ? promptCancel :
            promptFocusKind == 2 ? promptCreate :
            promptFocusKind == 3 ? promptClear :
            promptFocusKind == 4 ? promptSuppression : (AccessibleNode *)composerEditor;
        set_focused(next);
        return;
    }
    if (windowFocused && frame && frame->children->len) {
        if (conversationConfigurationMenuKind && conversationConfigurationMenu->children->len) {
            next = g_ptr_array_index(conversationConfigurationMenu->children, 0);
            for (guint i = 0; i < conversationConfigurationMenu->children->len; i++) {
                AccessibleNode *row = g_ptr_array_index(conversationConfigurationMenu->children, i);
                if (row->highlighted) { next = row; break; }
            }
            set_focused(next);
            return;
        }
        if (conversationSpeedMenuVisible && conversationSpeedMenu && conversationSpeedMenu->children->len) {
            next = g_ptr_array_index(conversationSpeedMenu->children, 0);
            for (guint i = 0; i < conversationSpeedMenu->children->len; i++) {
                AccessibleNode *row = g_ptr_array_index(conversationSpeedMenu->children, i);
                if (row->highlighted) { next = row; break; }
            }
            set_focused(next);
            return;
        }
        if (composerMenuVisible && composerMenuList && composerMenuList->children->len) {
            next = g_ptr_array_index(composerMenuList->children, 0);
            for (guint i = 0; i < composerMenuList->children->len; i++) {
                AccessibleNode *row = g_ptr_array_index(composerMenuList->children, i);
                if (row->highlighted) { next = row; break; }
            }
            set_focused(next);
            return;
        }
        if (sessionMenuVisible && sessionMenuList && sessionMenuList->children->len) {
            next = g_ptr_array_index(sessionMenuList->children, 0);
            for (guint i = 0; i < sessionMenuList->children->len; i++) {
                AccessibleNode *row = g_ptr_array_index(sessionMenuList->children, i);
                if (row->selected) { next = row; break; }
            }
            set_focused(next);
            return;
        }
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
        } else if (content == (AccessibleNode *)terminal) {
            next = conversationConfigurationVisible[0] && conversationConfigurationFocused[0]
                ? conversationConfigurationChips[0]
                : conversationConfigurationVisible[1] && conversationConfigurationFocused[1]
                ? conversationConfigurationChips[1]
                : conversationConfigurationVisible[2] && conversationConfigurationFocused[2]
                ? conversationConfigurationChips[2]
                : conversationSpeedVisible && conversationSpeedFocused ? conversationSpeedChip : content;
        }
        else if (content == placeholder && composerEditorVisible) {
            if (composerFocusKind == 1 && composerChipVisible[0]) next = composerProjectChip;
            else if (composerFocusKind == 2 && composerChipVisible[1]) next = composerProviderChip;
            else if (composerFocusKind == 5 && composerChipVisible[2]) next = composerPermissionChip;
            else if (composerFocusKind == 6 && composerChipVisible[3]) next = composerModelChip;
            else if (composerFocusKind == 7 && composerChipVisible[4]) next = composerSurfaceChip;
            else if (composerFocusKind == 8 && composerChipVisible[5]) next = composerSpeedChip;
            else if ((composerFocusKind == 3 || composerFocusKind == -1) && composerEditorFocused)
                next = (AccessibleNode *)composerEditor;
            else if ((composerFocusKind == 4 || composerFocusKind == -1) && placeholderActionVisible)
                next = placeholderAction;
        }
        else if (content == placeholder && placeholderActionVisible) next = placeholderAction;
    }
    set_focused(next);
}
static void show_content(AccessibleNode *content) {
    if (!frame) return;
    const int workspace = tw_workspace_sidebar_width(hostWindow) != 0;
    const int titleVisible = workspace && pageTitleVisible &&
        (!placeholderVisible || tw_workspace_terminal_top_inset_value(hostWindow) > 0);
    AccessibleNode *rightPane = placeholderVisible ? placeholder : (AccessibleNode *)terminal;
    const guint baseCount = workspace ? 2 + titleVisible : 1;
    const guint count = baseCount + actionsVisible + addProjectVisible + settingsVisible
        + pageActionsVisible + 2 * openInVisible + sessionMenuVisible;
    int same = frame->children->len == count
        && g_ptr_array_index(frame->children, 0) == (workspace ? list : content);
    if (same && titleVisible) same = g_ptr_array_index(frame->children, 1) == pageTitleButton;
    if (same && workspace) same = g_ptr_array_index(frame->children, 1 + titleVisible) == rightPane;
    if (same && actionsVisible) same = g_ptr_array_index(frame->children, baseCount) == actionsButton;
    if (same && addProjectVisible)
        same = g_ptr_array_index(frame->children, baseCount + actionsVisible) == addProjectButton;
    if (same && settingsVisible)
        same = g_ptr_array_index(frame->children, baseCount + actionsVisible + addProjectVisible)
            == settingsButton;
    if (same && pageActionsVisible)
        same = g_ptr_array_index(frame->children, baseCount + actionsVisible + addProjectVisible
                                + settingsVisible)
            == pageActionsButton;
    const guint openInIndex = baseCount + actionsVisible + addProjectVisible + settingsVisible
        + pageActionsVisible;
    if (same && openInVisible)
        same = g_ptr_array_index(frame->children, openInIndex) == openInPrimaryButton &&
            g_ptr_array_index(frame->children, openInIndex + 1) == openInChooserButton;
    if (same && sessionMenuVisible)
        same = g_ptr_array_index(frame->children, count - 1) == sessionMenuList;
    if (!same) {
        set_focused(NULL);
        clear_children(frame);
        add_child(frame, workspace ? list : content);
        if (titleVisible) add_child(frame, pageTitleButton);
        if (workspace) add_child(frame, rightPane);
        if (actionsVisible) add_child(frame, actionsButton);
        if (addProjectVisible) add_child(frame, addProjectButton);
        if (settingsVisible) add_child(frame, settingsButton);
        if (pageActionsVisible) add_child(frame, pageActionsButton);
        if (openInVisible) {
            add_child(frame, openInPrimaryButton);
            add_child(frame, openInChooserButton);
        }
        if (sessionMenuVisible) add_child(frame, sessionMenuList);
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

static int composer_chip_kind(AccessibleNode *node) {
    if (node == composerProjectChip) return 1;
    if (node == composerProviderChip) return 2;
    if (node == composerPermissionChip) return 3;
    if (node == composerModelChip) return 4;
    if (node == composerSurfaceChip) return 5;
    if (node == composerSpeedChip) return 6;
    return 0;
}
static AccessibleNode *composer_chip(int kind) {
    switch (kind) {
    case 1: return composerProjectChip;
    case 2: return composerProviderChip;
    case 3: return composerPermissionChip;
    case 4: return composerModelChip;
    case 5: return composerSurfaceChip;
    case 6: return composerSpeedChip;
    default: return NULL;
    }
}

static int attachment_button_slot(AccessibleNode *button) {
    if (!attachmentList || !attachmentScope || button->retired || !button->enabled ||
        atk_object_get_role(ATK_OBJECT(button)) != ATK_ROLE_PUSH_BUTTON) return -1;
    AtkObject *imageObject = atk_object_get_parent(ATK_OBJECT(button));
    if (!imageObject || atk_object_get_parent(imageObject) != ATK_OBJECT(attachmentList)) return -1;
    AccessibleNode *image = (AccessibleNode *)imageObject;
    const int slot = image->row;
    if (image->retired || slot < 0 || (guint)slot >= attachmentList->children->len ||
        g_ptr_array_index(attachmentList->children, (guint)slot) != image ||
        image->children->len != 1 || g_ptr_array_index(image->children, 0) != button ||
        !node_mounted(ATK_OBJECT(button))) return -1;
    return slot;
}

static gint action_count(AtkAction *action) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (attachment_button_slot(node) >= 0) return 1;
    if (attachmentList && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(attachmentList))
        return 0;
    for (int kind = 0; kind < 3; kind++) if (node == conversationConfigurationChips[kind])
        return conversationConfigurationVisible[kind] && node->enabled &&
            node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(conversationConfigurationMenu))
        return conversationConfigurationMenuKind && !node->retired && node->enabled &&
            node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == conversationSpeedChip ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(conversationSpeedMenu)))
        return conversationSpeedVisible && node->enabled && !node->retired &&
            node_mounted(ATK_OBJECT(node)) &&
            (node == conversationSpeedChip || conversationSpeedMenuVisible) ? 1 : 0;
    if (composer_chip_kind(node) != 0) {
        const int kind = composer_chip_kind(node);
        return placeholderVisible && composerEditorVisible && composerChipVisible[kind - 1] &&
            node->enabled && node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    }
    if (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(composerMenuList))
        return composerMenuVisible && !node->retired && node->enabled &&
            node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == actionsButton) return actionsVisible && node->enabled ? 1 : 0;
    if (node == settingsButton) return settingsVisible && node->enabled &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == pageActionsButton) return pageActionsVisible && node->enabled &&
        strcmp(pageActionsIdentity, pageTitleIdentity) == 0 &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == openInPrimaryButton || node == openInChooserButton)
        return openInVisible && !sessionMenuVisible && node->enabled &&
            strcmp(openInIdentity, pageTitleIdentity) == 0 &&
            node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == pageTitleButton) return pageTitleVisible && node->enabled &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == placeholderAction) return placeholderVisible && placeholderActionVisible &&
        node->enabled && node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == promptCancel || node == promptCreate || node == promptClear ||
        node == promptSuppression)
        return promptVisible && node->enabled && node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node == addProjectButton) return addProjectVisible && node->enabled &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node->projectControl) return !node->retired && node->enabled &&
        node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    if (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(sessionMenuList))
        return sessionMenuVisible && !node->retired && node->enabled &&
            node_mounted(ATK_OBJECT(node)) ? 1 : 0;
    return node->row < 0 ? 0 : (node->canOpen && node->enabled ? 2 : 1);
}
static const gchar *action_name(AtkAction *action, gint index) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (attachment_button_slot(node) >= 0) return index == 0 ? "press" : NULL;
    if (attachmentList && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(attachmentList))
        return NULL;
    if (node == conversationConfigurationChips[0] || node == conversationConfigurationChips[1] ||
        node == conversationConfigurationChips[2] ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(conversationConfigurationMenu)))
        return index == 0 && action_count(action) ? "press" : NULL;
    if (node == conversationSpeedChip ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(conversationSpeedMenu)))
        return index == 0 && action_count(action) ? "press" : NULL;
    if (composer_chip_kind(node) != 0 ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(composerMenuList)))
        return index == 0 && action_count(action) ? "press" : NULL;
    if (node == actionsButton || node == addProjectButton || node == settingsButton ||
        node == pageTitleButton ||
        node == pageActionsButton || node == openInPrimaryButton ||
        node == openInChooserButton ||
        node == placeholderAction || node == promptCancel || node == promptCreate ||
        node == promptClear || node == promptSuppression ||
        node->projectControl)
        return index == 0 && action_count(action) ? "press" : NULL;
    if (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(sessionMenuList))
        return index == 0 && action_count(action) ? "press" : NULL;
    if (node->row < 0) return NULL;
    return index == 0 ? "select" : (index == 1 && node->canOpen && node->enabled ? "open" : NULL);
}
static gboolean action_do(AtkAction *action, gint index) {
    AccessibleNode *node = (AccessibleNode *)action;
    if (node == promptCancel || node == promptCreate || node == promptClear ||
        node == promptSuppression) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        event.user.code = 20;
        event.user.data1 = (void *)(intptr_t)(node == promptCreate ? 1 :
            node == promptClear ? 2 : node == promptSuppression ? 3 : 0);
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    const int attachmentSlot = attachment_button_slot(node);
    if (attachmentSlot >= 0) {
        if (index != 0 || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        event.user.code = 19;
        event.user.data1 = (void *)(intptr_t)attachmentSlot;
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node == conversationConfigurationChips[0] || node == conversationConfigurationChips[1] ||
        node == conversationConfigurationChips[2] ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(conversationConfigurationMenu))) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        const int kind = node == conversationConfigurationChips[0] ? 1
            : node == conversationConfigurationChips[1] ? 2
            : node == conversationConfigurationChips[2] ? 3 : conversationConfigurationMenuKind;
        event.user.code = node == conversationConfigurationChips[0] ||
            node == conversationConfigurationChips[1] ||
            node == conversationConfigurationChips[2] ? 17 : 18;
        event.user.data1 = (void *)(intptr_t)(event.user.code == 17 ? kind : node->row);
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node == conversationSpeedChip ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(conversationSpeedMenu))) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        event.user.code = node == conversationSpeedChip ? 15 : 16;
        event.user.data1 = (void *)(intptr_t)(node == conversationSpeedChip ? -1 : node->row);
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node == openInPrimaryButton || node == openInChooserButton) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        event.user.code = 14;
        event.user.data1 = (void *)(intptr_t)(node == openInPrimaryButton ? 1 : 2);
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (composer_chip_kind(node) != 0 ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(composerMenuList))) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        event.user.code = composer_chip_kind(node) != 0 ? 12 : 13;
        event.user.data1 = (void *)(intptr_t)(event.user.code == 12
            ? (composer_chip_kind(node)) : node->row);
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
    if (node == pageActionsButton ||
        (node->row >= 0 && atk_object_get_parent(ATK_OBJECT(node)) == ATK_OBJECT(sessionMenuList))) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType;
        event.user.code = node == pageActionsButton ? 9 : 10;
        event.user.data1 = (void *)(intptr_t)(node == pageActionsButton ? 0 : node->row);
        event.user.data2 = (void *)(uintptr_t)generation;
        int pushed = SDL_PushEvent(&event);
        navigation_trace_enqueue(&event, pushed);
        return pushed == 1;
    }
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
        if (index != 0 || !action_count(action) || !node->enabled ||
            eventType == UINT32_MAX) return FALSE;
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
    if (node == settingsButton) {
        if (index != 0 || !action_count(action) || eventType == UINT32_MAX) return FALSE;
        SDL_Event event = {0};
        event.type = eventType; event.user.code = 21;
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
    } else if (object == ATK_OBJECT(promptPanel) || object == ATK_OBJECT(promptTitle) ||
               object == ATK_OBJECT(promptMessage) || object == ATK_OBJECT(promptCancel) ||
               object == ATK_OBJECT(promptCreate) || object == ATK_OBJECT(promptClear) ||
               object == ATK_OBJECT(promptSuppression)) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (object == ATK_OBJECT(actionsButton) || object == ATK_OBJECT(addProjectButton) ||
               object == ATK_OBJECT(settingsButton) ||
               object == ATK_OBJECT(pageTitleButton) || object == ATK_OBJECT(pageActionsButton) ||
               object == ATK_OBJECT(openInPrimaryButton) ||
               object == ATK_OBJECT(openInChooserButton) ||
               object == ATK_OBJECT(placeholderTitle) ||
               object == ATK_OBJECT(placeholderAction) || object == ATK_OBJECT(composerEditor) ||
               object == ATK_OBJECT(composerProjectChip) ||
               object == ATK_OBJECT(conversationSpeedChip) ||
               object == ATK_OBJECT(conversationContextLabel) ||
               object == ATK_OBJECT(conversationConfigurationChips[0]) ||
               object == ATK_OBJECT(conversationConfigurationChips[1]) ||
               object == ATK_OBJECT(conversationConfigurationChips[2]) ||
               (object == ATK_OBJECT(composerProviderChip) || object == ATK_OBJECT(composerPermissionChip) ||
                object == ATK_OBJECT(composerModelChip) || object == ATK_OBJECT(composerSurfaceChip) ||
                object == ATK_OBJECT(composerSpeedChip))) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (attachmentList &&
               (object == ATK_OBJECT(attachmentList) ||
                atk_object_get_parent(object) == ATK_OBJECT(attachmentList) ||
                (atk_object_get_parent(object) &&
                 atk_object_get_parent(atk_object_get_parent(object)) == ATK_OBJECT(attachmentList)))) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (object == ATK_OBJECT(list) || object == ATK_OBJECT(sessionMenuList) ||
               object == ATK_OBJECT(composerMenuList) || object == ATK_OBJECT(conversationSpeedMenu) ||
               object == ATK_OBJECT(conversationConfigurationMenu)) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (node->projectControl && node->actionRow >= 0 &&
               atk_object_get_parent(object) != NULL) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else if (node->row >= 0 &&
               (atk_object_get_parent(object) == ATK_OBJECT(list) ||
                atk_object_get_parent(object) == ATK_OBJECT(sessionMenuList) ||
                atk_object_get_parent(object) == ATK_OBJECT(composerMenuList) ||
                atk_object_get_parent(object) == ATK_OBJECT(conversationSpeedMenu) ||
                atk_object_get_parent(object) == ATK_OBJECT(conversationConfigurationMenu))) {
        *x = node->bounds.x; *y = node->bounds.y;
        *width = node->bounds.width; *height = node->bounds.height;
    } else return 0;
    if (coordinates == ATK_XY_SCREEN) { *x += originX; *y += originY; }
    else if (coordinates == ATK_XY_PARENT && attachmentList &&
             object == ATK_OBJECT(attachmentList)) {
        *x -= tw_workspace_sidebar_width(hostWindow);
        if (attachmentScope == 2) *y -= tw_workspace_terminal_top_inset_value(hostWindow);
    }
    else if (coordinates == ATK_XY_PARENT && attachmentList &&
             (atk_object_get_parent(object) == ATK_OBJECT(attachmentList) ||
              (atk_object_get_parent(object) &&
               atk_object_get_parent(atk_object_get_parent(object)) == ATK_OBJECT(attachmentList)))) {
        AccessibleNode *parent = (AccessibleNode *)atk_object_get_parent(object);
        *x -= parent->bounds.x; *y -= parent->bounds.y;
    }
    else if (coordinates == ATK_XY_PARENT &&
             (object == ATK_OBJECT(conversationSpeedChip) ||
              object == ATK_OBJECT(conversationSpeedMenu) ||
              object == ATK_OBJECT(conversationContextLabel) ||
              object == ATK_OBJECT(conversationConfigurationChips[0]) ||
              object == ATK_OBJECT(conversationConfigurationChips[1]) ||
              object == ATK_OBJECT(conversationConfigurationChips[2]) ||
              object == ATK_OBJECT(conversationConfigurationMenu))) {
        *x -= tw_workspace_sidebar_width(hostWindow);
        *y -= tw_workspace_terminal_top_inset_value(hostWindow);
    }
    else if (coordinates == ATK_XY_PARENT &&
             (object == ATK_OBJECT(placeholderTitle) ||
              object == ATK_OBJECT(placeholderAction) || object == ATK_OBJECT(composerEditor) ||
              object == ATK_OBJECT(composerProjectChip) ||
              (object == ATK_OBJECT(composerProviderChip) || object == ATK_OBJECT(composerPermissionChip) ||
               object == ATK_OBJECT(composerModelChip) || object == ATK_OBJECT(composerSurfaceChip) ||
               object == ATK_OBJECT(composerSpeedChip)) ||
              object == ATK_OBJECT(composerMenuList))) {
        *x -= tw_workspace_sidebar_width(hostWindow);
    }
    else if (coordinates == ATK_XY_PARENT && node->projectControl) {
        AccessibleNode *row = (AccessibleNode *)atk_object_get_parent(object);
        *x -= row->bounds.x; *y -= row->bounds.y;
    }
    else if (coordinates == ATK_XY_PARENT && node->row >= 0) {
        AccessibleNode *parent = (AccessibleNode *)atk_object_get_parent(object);
        *x -= parent->bounds.x; *y -= parent->bounds.y;
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
    if (node == frame && sessionMenuVisible &&
        atk_component_contains(ATK_COMPONENT(sessionMenuList), x, y, ATK_XY_WINDOW))
        return ATK_OBJECT(g_object_ref(sessionMenuList));
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
static gchar *composer_get_text(AtkText *text, gint start, gint end) {
    ComposerEditorNode *node = (ComposerEditorNode *)text;
    if (start < 0 || start > node->characters || end < -1) return g_strdup("");
    if (end == -1 || end > node->characters) end = node->characters;
    if (end < start) return g_strdup("");
    const char *first = g_utf8_offset_to_pointer(node->text, start);
    const char *last = g_utf8_offset_to_pointer(first, end - start);
    return g_strndup(first, (gsize)(last - first));
}
static gunichar composer_character(AtkText *text, gint offset) {
    ComposerEditorNode *node = (ComposerEditorNode *)text;
    if (offset < 0 || offset >= node->characters) return 0;
    return g_utf8_get_char(g_utf8_offset_to_pointer(node->text, offset));
}
static gint composer_character_count(AtkText *text) {
    return ((ComposerEditorNode *)text)->characters;
}
static gint composer_caret(AtkText *text) {
    return ((ComposerEditorNode *)text)->selectionEnd;
}
static gint composer_selections(AtkText *text) {
    ComposerEditorNode *node = (ComposerEditorNode *)text;
    return node->selectionStart < node->selectionEnd ? 1 : 0;
}
static gchar *composer_selection(AtkText *text, gint index, gint *start, gint *end) {
    ComposerEditorNode *node = (ComposerEditorNode *)text;
    if (start) *start = -1;
    if (end) *end = -1;
    if (index != 0 || node->selectionStart == node->selectionEnd) return NULL;
    if (start) *start = node->selectionStart;
    if (end) *end = node->selectionEnd;
    return composer_get_text(text, node->selectionStart, node->selectionEnd);
}
static gchar *composer_string_at(AtkText *text, gint offset, AtkTextGranularity granularity,
                                 gint *start, gint *end) {
    ComposerEditorNode *node = (ComposerEditorNode *)text;
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
    } else if (granularity != ATK_TEXT_GRANULARITY_CHAR) return NULL;
    *start = first; *end = last;
    return g_strndup(left, (gsize)(right - left));
}
static void free_composer_edit(gpointer data) {
    ComposerEdit *edit = data;
    g_free(edit->text);
    g_free(edit);
}
static void clear_composer_edits(void) {
    if (composerEdits) g_queue_clear_full(composerEdits, free_composer_edit);
    composerPredictedCharacters = 0;
    composerPredictionValid = 0;
    composerIncarnation++;
    if (!composerIncarnation) composerIncarnation++;
}
static gboolean enqueue_composer_edit(int operation, int start, int end,
                                      const char *text, int length) {
    if (!bridgeReady || !composerEditorVisible || !composerEdits ||
        !node_mounted(ATK_OBJECT(composerEditor)) || !composerIdentity[0] ||
        !composerPredictionValid ||
        g_queue_get_length(composerEdits) >= MAX_COMPOSER_EDITS ||
        start < 0 || end < start || end > composerPredictedCharacters ||
        length < 0 || length > MAX_COMPOSER_TEXT || (length && !text) ||
        (text && (memchr(text, 0, (size_t)length) || !g_utf8_validate(text, length, NULL))) ||
        eventType == UINT32_MAX) return FALSE;
    int nextCharacters = composerPredictedCharacters;
    if (operation == 1) nextCharacters += (int)g_utf8_strlen(text ? text : "", length) - (end - start);
    else if (operation == 4) nextCharacters -= end - start;
    if (nextCharacters < 0 || nextCharacters > MAX_COMPOSER_TEXT) return FALSE;
    ComposerEdit *edit = g_new0(ComposerEdit, 1);
    edit->serial = ++composerEditSerial;
    if (!edit->serial) edit->serial = ++composerEditSerial;
    edit->incarnation = composerIncarnation;
    edit->operation = operation;
    edit->start = start;
    edit->end = end;
    edit->length = length;
    g_strlcpy(edit->identity, composerIdentity, sizeof(edit->identity));
    edit->text = g_strndup(text ? text : "", (gsize)length);
    SDL_Event event = {0};
    event.type = eventType;
    event.user.code = 11;
    event.user.data1 = (void *)(uintptr_t)edit->serial;
    event.user.data2 = (void *)(uintptr_t)edit->incarnation;
    if (SDL_PushEvent(&event) != 1) { free_composer_edit(edit); return FALSE; }
    g_queue_push_tail(composerEdits, edit);
    composerPredictedCharacters = nextCharacters;
    if (operation == 5) composerPredictionValid = 0; // Clipboard size belongs to the host.
    return TRUE;
}
static gboolean composer_set_caret(AtkText *text, gint offset) {
    (void)text;
    return enqueue_composer_edit(2, offset, offset, NULL, 0);
}
static gboolean composer_add_selection(AtkText *text, gint start, gint end) {
    (void)text;
    return enqueue_composer_edit(2, start, end, NULL, 0);
}
static gboolean composer_remove_selection(AtkText *text, gint index) {
    ComposerEditorNode *node = (ComposerEditorNode *)text;
    if (index != 0 || node->selectionStart == node->selectionEnd) return FALSE;
    return enqueue_composer_edit(2, node->selectionEnd, node->selectionEnd, NULL, 0);
}
static gboolean composer_set_selection(AtkText *text, gint index, gint start, gint end) {
    (void)text;
    if (index != 0) return FALSE;
    return enqueue_composer_edit(2, start, end, NULL, 0);
}
static void composer_set_contents(AtkEditableText *text, const gchar *value) {
    (void)text;
    if (!value) return;
    size_t length = strnlen(value, MAX_COMPOSER_TEXT + 1);
    if (length > MAX_COMPOSER_TEXT) return;
    enqueue_composer_edit(1, 0, composerPredictedCharacters, value, (int)length);
}
static void composer_insert(AtkEditableText *text, const gchar *value, gint length,
                            gint *position) {
    (void)text;
    if (!value || !position || *position < 0 || length < -1) return;
    size_t measured = strnlen(value, MAX_COMPOSER_TEXT + 1);
    if (measured > MAX_COMPOSER_TEXT || (length >= 0 && (size_t)length > measured)) return;
    if (length == -1) length = (gint)measured;
    if (length > MAX_COMPOSER_TEXT ||
        !enqueue_composer_edit(1, *position, *position, value, length)) return;
    *position += (gint)g_utf8_strlen(value, length);
}
static void composer_copy(AtkEditableText *text, gint start, gint end) {
    (void)text;
    enqueue_composer_edit(3, start, end, NULL, 0);
}
static void composer_cut(AtkEditableText *text, gint start, gint end) {
    (void)text;
    enqueue_composer_edit(4, start, end, NULL, 0);
}
static void composer_delete(AtkEditableText *text, gint start, gint end) {
    (void)text;
    enqueue_composer_edit(1, start, end, NULL, 0);
}
static void composer_paste(AtkEditableText *text, gint position) {
    (void)text;
    enqueue_composer_edit(5, position, position, NULL, 0);
}
static void composer_editable_interface_init(AtkEditableTextIface *iface) {
    iface->set_text_contents = composer_set_contents;
    iface->insert_text = composer_insert;
    iface->copy_text = composer_copy;
    iface->cut_text = composer_cut;
    iface->delete_text = composer_delete;
    iface->paste_text = composer_paste;
}
static void composer_text_interface_init(AtkTextIface *iface) {
    iface->get_text = composer_get_text;
    iface->get_character_at_offset = composer_character;
    iface->get_character_count = composer_character_count;
    iface->get_caret_offset = composer_caret;
    iface->get_n_selections = composer_selections;
    iface->get_selection = composer_selection;
    iface->get_string_at_offset = composer_string_at;
    iface->set_caret_offset = composer_set_caret;
    iface->add_selection = composer_add_selection;
    iface->remove_selection = composer_remove_selection;
    iface->set_selection = composer_set_selection;
}
static void composer_editor_node_finalize(GObject *object) {
    g_free(((ComposerEditorNode *)object)->text);
    G_OBJECT_CLASS(composer_editor_node_parent_class)->finalize(object);
}
static void composer_editor_node_class_init(ComposerEditorNodeClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = composer_editor_node_finalize;
}
static void composer_editor_node_init(ComposerEditorNode *node) {
    node->text = g_strdup("");
}
static void set_composer_text(const char *value, int length, int characters,
                              int selectionStart, int selectionEnd) {
    ComposerEditorNode *node = composerEditor;
    const int changed = node->length != length || memcmp(node->text, value, (size_t)length) != 0;
    if (changed) {
        char *oldText = node->text;
        const char *oldFirst = oldText, *newFirst = value;
        const char *oldLast = oldText + node->length, *newLast = value + length;
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
        const int removed = (int)g_utf8_strlen(oldFirst, oldLast - oldFirst);
        const int inserted = (int)g_utf8_strlen(newFirst, newLast - newFirst);
        char *removedText = removed ? g_strndup(oldFirst, (gsize)(oldLast - oldFirst)) : NULL;
        char *insertedText = inserted ? g_strndup(newFirst, (gsize)(newLast - newFirst)) : NULL;
        node->text = g_strndup(value, (gsize)length);
        node->length = length;
        node->characters = characters;
        if (removed) g_signal_emit_by_name(node, "text-remove::system", firstCharacter, removed, removedText);
        if (inserted) g_signal_emit_by_name(node, "text-insert::system", firstCharacter, inserted, insertedText);
        g_free(removedText);
        g_free(insertedText);
        g_free(oldText);
    }
    const int selectionChanged = node->selectionStart != selectionStart || node->selectionEnd != selectionEnd;
    const int caretChanged = node->selectionEnd != selectionEnd;
    node->selectionStart = selectionStart;
    node->selectionEnd = selectionEnd;
    if (selectionChanged) g_signal_emit_by_name(node, "text-selection-changed");
    if (caretChanged) g_signal_emit_by_name(node, "text-caret-moved", selectionEnd);
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
    settingsButton = new_component(ATK_ROLE_PUSH_BUTTON, "Settings");
    settingsButton->id = g_strdup("sidebar.settings");
    atk_object_set_accessible_id(ATK_OBJECT(settingsButton), settingsButton->id);
    pageTitleButton = new_component(ATK_ROLE_PUSH_BUTTON, "Page title");
    pageTitleButton->id = g_strdup("linux.page-title");
    atk_object_set_accessible_id(ATK_OBJECT(pageTitleButton), pageTitleButton->id);
    pageActionsButton = new_component(ATK_ROLE_PUSH_BUTTON, "Session actions");
    pageActionsButton->id = g_strdup("linux.page-actions");
    atk_object_set_accessible_id(ATK_OBJECT(pageActionsButton), pageActionsButton->id);
    openInPrimaryButton = new_component(ATK_ROLE_PUSH_BUTTON, "Open In");
    openInPrimaryButton->id = g_strdup("linux.open-in.primary");
    atk_object_set_accessible_id(ATK_OBJECT(openInPrimaryButton), openInPrimaryButton->id);
    openInChooserButton = new_component(ATK_ROLE_PUSH_BUTTON, "Choose application");
    openInChooserButton->id = g_strdup("linux.open-in.chooser");
    atk_object_set_accessible_id(ATK_OBJECT(openInChooserButton), openInChooserButton->id);
    sessionMenuList = new_component(ATK_ROLE_LIST, "Session actions");
    sessionMenuList->id = g_strdup("linux.session-actions");
    atk_object_set_accessible_id(ATK_OBJECT(sessionMenuList), sessionMenuList->id);
    placeholder = new_component(ATK_ROLE_PANEL, "Session placeholder");
    placeholderTitle = new_component(ATK_ROLE_LABEL, "");
    atk_object_set_accessible_id(ATK_OBJECT(placeholderTitle), "linux.composer.greeting");
    placeholderDetail = new_node(ATK_ROLE_LABEL, "");
    placeholderAction = new_component(ATK_ROLE_PUSH_BUTTON, "New Session");
    placeholderAction->id = g_strdup("linux.placeholder.action");
    atk_object_set_accessible_id(ATK_OBJECT(placeholderAction), placeholderAction->id);
    promptPanel = new_component(ATK_ROLE_DIALOG, "New Worktree");
    promptPanel->id = g_strdup("linux.prompt.worktree");
    atk_object_set_accessible_id(ATK_OBJECT(promptPanel), promptPanel->id);
    promptTitle = new_component(ATK_ROLE_LABEL, "New Worktree");
    promptMessage = new_component(ATK_ROLE_LABEL, "");
    promptCancel = new_component(ATK_ROLE_PUSH_BUTTON, "Cancel");
    promptCancel->id = g_strdup("linux.prompt.cancel");
    atk_object_set_accessible_id(ATK_OBJECT(promptCancel), promptCancel->id);
    promptCreate = new_component(ATK_ROLE_PUSH_BUTTON, "Create");
    promptCreate->id = g_strdup("linux.prompt.create");
    atk_object_set_accessible_id(ATK_OBJECT(promptCreate), promptCreate->id);
    promptClear = new_component(ATK_ROLE_PUSH_BUTTON, "Use Agent's Name");
    promptClear->id = g_strdup("linux.prompt.clear");
    atk_object_set_accessible_id(ATK_OBJECT(promptClear), promptClear->id);
    promptSuppression = new_component(ATK_ROLE_CHECK_BOX, "Don't ask again");
    promptSuppression->id = g_strdup("linux.prompt.suppression");
    atk_object_set_accessible_id(ATK_OBJECT(promptSuppression), promptSuppression->id);
    composerProjectChip = new_component(ATK_ROLE_COMBO_BOX, "Project");
    composerProjectChip->id = g_strdup("linux.composer.project");
    atk_object_set_accessible_id(ATK_OBJECT(composerProjectChip), composerProjectChip->id);
    composerProviderChip = new_component(ATK_ROLE_COMBO_BOX, "Provider");
    composerProviderChip->id = g_strdup("linux.composer.provider");
    atk_object_set_accessible_id(ATK_OBJECT(composerProviderChip), composerProviderChip->id);
    composerPermissionChip = new_component(ATK_ROLE_COMBO_BOX, "Permissions");
    composerPermissionChip->id = g_strdup("linux.composer.permissions");
    atk_object_set_accessible_id(ATK_OBJECT(composerPermissionChip), composerPermissionChip->id);
    composerModelChip = new_component(ATK_ROLE_COMBO_BOX, "Model and effort");
    composerModelChip->id = g_strdup("linux.composer.model-effort");
    atk_object_set_accessible_id(ATK_OBJECT(composerModelChip), composerModelChip->id);
    composerSurfaceChip = new_component(ATK_ROLE_COMBO_BOX, "Interface");
    composerSurfaceChip->id = g_strdup("linux.composer.surface");
    atk_object_set_accessible_id(ATK_OBJECT(composerSurfaceChip), composerSurfaceChip->id);
    composerSpeedChip = new_component(ATK_ROLE_COMBO_BOX, "Speed");
    composerSpeedChip->id = g_strdup("linux.composer.speed");
    atk_object_set_accessible_id(ATK_OBJECT(composerSpeedChip), composerSpeedChip->id);
    composerMenuList = new_component(ATK_ROLE_LIST, "Composer choices");
    composerMenuList->id = g_strdup("linux.composer.choices");
    atk_object_set_accessible_id(ATK_OBJECT(composerMenuList), composerMenuList->id);
    conversationSpeedChip = new_component(ATK_ROLE_COMBO_BOX, "Speed");
    conversationSpeedChip->id = g_strdup("linux.conversation.speed");
    atk_object_set_accessible_id(ATK_OBJECT(conversationSpeedChip), conversationSpeedChip->id);
    conversationSpeedMenu = new_component(ATK_ROLE_LIST, "Speed choices");
    conversationSpeedMenu->id = g_strdup("linux.conversation.speed.choices");
    atk_object_set_accessible_id(ATK_OBJECT(conversationSpeedMenu), conversationSpeedMenu->id);
    conversationSpeedIdentity[0] = '\0';
    conversationSpeedVisible = conversationSpeedMenuVisible = conversationSpeedFocused = 0;
    conversationContextLabel = new_component(ATK_ROLE_LABEL, "Context");
    conversationContextLabel->id = g_strdup("linux.conversation.context");
    atk_object_set_accessible_id(ATK_OBJECT(conversationContextLabel), conversationContextLabel->id);
    conversationContextIdentity[0] = '\0';
    conversationContextVisible = 0;
    conversationConfigurationChips[0] = new_component(ATK_ROLE_COMBO_BOX, "Model");
    conversationConfigurationChips[0]->id = g_strdup("linux.conversation.model");
    atk_object_set_accessible_id(ATK_OBJECT(conversationConfigurationChips[0]),
        conversationConfigurationChips[0]->id);
    conversationConfigurationChips[1] = new_component(ATK_ROLE_COMBO_BOX, "Effort");
    conversationConfigurationChips[1]->id = g_strdup("linux.conversation.effort");
    atk_object_set_accessible_id(ATK_OBJECT(conversationConfigurationChips[1]),
        conversationConfigurationChips[1]->id);
    conversationConfigurationChips[2] = new_component(ATK_ROLE_COMBO_BOX, "Mode");
    conversationConfigurationChips[2]->id = g_strdup("linux.conversation.mode");
    atk_object_set_accessible_id(ATK_OBJECT(conversationConfigurationChips[2]),
        conversationConfigurationChips[2]->id);
    conversationConfigurationMenu = new_component(ATK_ROLE_LIST, "Configuration choices");
    attachmentList = new_component(ATK_ROLE_PANEL, "Attachments");
    attachmentScope = 0;
    attachmentOwner[0] = '\0';
    attachmentPending.scope = attachmentPending.count = 0;
    conversationConfigurationIdentity[0] = '\0';
    conversationConfigurationVisible[0] = conversationConfigurationVisible[1] = conversationConfigurationVisible[2] = 0;
    conversationConfigurationFocused[0] = conversationConfigurationFocused[1] = conversationConfigurationFocused[2] = 0;
    conversationConfigurationMenuKind = conversationConfigurationFirst = 0;
    composerEdits = g_queue_new();
    composerIdentity[0] = '\0';
    composerMenuIdentity[0] = '\0';
    composerChipVisible[0] = composerChipVisible[1] = composerChipVisible[2] = composerChipVisible[3] = composerChipVisible[4] = composerChipVisible[5] = composerMenuVisible = composerMenuKind = 0;
    composerEditor = g_object_new(composer_editor_node_get_type(), NULL);
    atk_object_set_role(ATK_OBJECT(composerEditor), ATK_ROLE_TEXT);
    atk_object_set_name(ATK_OBJECT(composerEditor), "New session brief");
    atk_object_set_description(ATK_OBJECT(composerEditor), "Multiline brief for the new session.");
    ((AccessibleNode *)composerEditor)->id = g_strdup("linux.composer.editor");
    atk_object_set_accessible_id(ATK_OBJECT(composerEditor),
                                 ((AccessibleNode *)composerEditor)->id);
    actionsVisible = 0;
    addProjectVisible = 0;
    settingsVisible = 0;
    pageTitleVisible = pageActionsVisible = openInVisible = sessionMenuVisible = 0;
    placeholderVisible = placeholderActionVisible = composerEditorVisible = composerEditorFocused = 0;
    promptVisible = promptFocusKind = 0;
    pageTitleIdentity[0] = '\0';
    pageActionsIdentity[0] = openInIdentity[0] = sessionMenuIdentity[0] = '\0';
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
    clear_composer_edits();
    g_clear_pointer(&composerEdits, g_queue_free);
    composerIdentity[0] = '\0';
    if (bridgeReady) atk_bridge_adaptor_cleanup();
    bridgeReady = 0; activeList = NULL; eventType = UINT32_MAX; windowFocused = 0;
    clear_children(list);
    clear_children(sessionMenuList);
    clear_children(composerMenuList);
    clear_children(conversationSpeedMenu);
    clear_children(conversationConfigurationMenu);
    clear_children(attachmentList);
    clear_children(promptPanel);
    clear_children((AccessibleNode *)terminal);
    clear_children(frame);
    clear_children(app);
    g_clear_object(&app);
    g_clear_object(&frame);
    g_clear_object(&list);
    g_clear_object(&terminal);
    g_clear_object(&actionsButton);
    g_clear_object(&addProjectButton);
    g_clear_object(&settingsButton);
    g_clear_object(&pageTitleButton);
    g_clear_object(&pageActionsButton);
    g_clear_object(&openInPrimaryButton);
    g_clear_object(&openInChooserButton);
    g_clear_object(&sessionMenuList);
    g_clear_object(&placeholder);
    g_clear_object(&placeholderTitle);
    g_clear_object(&placeholderDetail);
    g_clear_object(&placeholderAction);
    g_clear_object(&promptPanel);
    g_clear_object(&promptTitle);
    g_clear_object(&promptMessage);
    g_clear_object(&promptCancel);
    g_clear_object(&promptCreate);
    g_clear_object(&promptClear);
    g_clear_object(&promptSuppression);
    g_clear_object(&composerProjectChip);
    g_clear_object(&composerProviderChip);
    g_clear_object(&composerPermissionChip);
    g_clear_object(&composerModelChip);
    g_clear_object(&composerSurfaceChip);
    g_clear_object(&composerSpeedChip);
    g_clear_object(&composerMenuList);
    g_clear_object(&conversationSpeedChip);
    g_clear_object(&conversationSpeedMenu);
    g_clear_object(&conversationContextLabel);
    g_clear_object(&conversationConfigurationChips[0]);
    g_clear_object(&conversationConfigurationChips[1]);
    g_clear_object(&conversationConfigurationChips[2]);
    g_clear_object(&conversationConfigurationMenu);
    g_clear_object(&attachmentList);
    g_clear_object(&composerEditor);
    actionsVisible = addProjectVisible = settingsVisible = pageTitleVisible = pageActionsVisible = 0;
    openInVisible = sessionMenuVisible = 0;
    placeholderVisible = placeholderActionVisible = composerEditorVisible = composerEditorFocused = 0;
    promptVisible = promptFocusKind = 0;
    composerChipVisible[0] = composerChipVisible[1] = composerChipVisible[2] = composerChipVisible[3] = composerChipVisible[4] = composerChipVisible[5] = composerMenuVisible = composerMenuKind = 0;
    composerMenuIdentity[0] = '\0';
    conversationSpeedIdentity[0] = '\0';
    conversationSpeedVisible = conversationSpeedMenuVisible = conversationSpeedFocused = 0;
    conversationContextIdentity[0] = '\0';
    conversationContextVisible = 0;
    conversationConfigurationIdentity[0] = '\0';
    conversationConfigurationVisible[0] = conversationConfigurationVisible[1] = conversationConfigurationVisible[2] = 0;
    conversationConfigurationFocused[0] = conversationConfigurationFocused[1] = conversationConfigurationFocused[2] = 0;
    conversationConfigurationMenuKind = conversationConfigurationFirst = 0;
    attachmentScope = 0;
    attachmentOwner[0] = '\0';
    attachmentPending.scope = attachmentPending.count = 0;
    pageTitleIdentity[0] = '\0';
    pageActionsIdentity[0] = openInIdentity[0] = sessionMenuIdentity[0] = '\0';
    tw_open_in_shortcut_state(hostWindow, NULL, 0);
    hostWindow = NULL;
    generation++;
}
static void clear_attachment_projection(void) {
    if (!attachmentList || !attachmentScope) return;
    clear_children(attachmentList);
    remove_child(placeholder, attachmentList);
    remove_child((AccessibleNode *)terminal, attachmentList);
    attachmentScope = 0;
    attachmentOwner[0] = '\0';
    generation++;
    rebuild_placeholder_children();
}

void tw_accessibility_attachments_begin(TWWindow *window, int scope, const char *owner) {
    attachmentPending.scope = attachmentPending.count = 0;
    attachmentPending.owner[0] = '\0';
    if (!bridgeReady || window != hostWindow || (scope != 1 && scope != 2) ||
        !owner || !owner[0] || strnlen(owner, MAX_COMPOSER_ID) >= MAX_COMPOSER_ID ||
        !g_utf8_validate(owner, -1, NULL) ||
        (scope == 1 && !composer_identity_valid(owner))) return;
    attachmentPending.scope = scope;
    g_strlcpy(attachmentPending.owner, owner, sizeof(attachmentPending.owner));
}

int tw_accessibility_attachments_add(TWWindow *window, const char *id, const char *name,
    int x, int y, int width, int height,
    int removeX, int removeY, int removeWidth, int removeHeight) {
    if (!bridgeReady || window != hostWindow || !attachmentPending.scope ||
        attachmentPending.count >= MAX_ATTACHMENT_TILES || !id || strlen(id) != 36 ||
        !name || strnlen(name, MAX_ATTACHMENT_NAME) >= MAX_ATTACHMENT_NAME ||
        !g_utf8_validate(name, -1, NULL) ||
        !composer_bounds_valid(window, x, y, width, height) ||
        !composer_bounds_valid(window, removeX, removeY, removeWidth, removeHeight) ||
        removeX < x || removeY < y || removeX + removeWidth > x + width ||
        removeY + removeHeight > y + height) return 0;
    for (int index = 0; index < 36; index++) {
        const int hyphen = index == 8 || index == 13 || index == 18 || index == 23;
        if (hyphen ? id[index] != '-' : !g_ascii_isxdigit(id[index])) return 0;
    }
    const int slot = attachmentPending.count++;
    g_strlcpy(attachmentPending.tiles[slot].id, id,
              sizeof(attachmentPending.tiles[slot].id));
    g_strlcpy(attachmentPending.tiles[slot].name, name,
              sizeof(attachmentPending.tiles[slot].name));
    attachmentPending.tiles[slot].bounds = (AtkRectangle){x, y, width, height};
    attachmentPending.tiles[slot].removeBounds =
        (AtkRectangle){removeX, removeY, removeWidth, removeHeight};
    return 1;
}
void tw_accessibility_attachments_end(TWWindow *window) {
    if (!bridgeReady || window != hostWindow) return;
    const int scope = attachmentPending.scope;
    const int count = attachmentPending.count;
    if (!scope || !count) { clear_attachment_projection(); return; }
    int same = attachmentScope == scope &&
        strcmp(attachmentOwner, attachmentPending.owner) == 0 &&
        attachmentList->children->len == (guint)count;
    for (int slot = 0; same && slot < count; slot++) {
        AccessibleNode *image = g_ptr_array_index(attachmentList->children, (guint)slot);
        same = image->id && strcmp(image->id, attachmentPending.tiles[slot].id) == 0 &&
            image->children->len == 1;
    }
    if (!same) {
        clear_attachment_projection();
        attachmentScope = scope;
        g_strlcpy(attachmentOwner, attachmentPending.owner, sizeof(attachmentOwner));
        atk_object_set_accessible_id(ATK_OBJECT(attachmentList), scope == 1
            ? "linux.composer.attachments" : "linux.conversation.attachments");
        for (int slot = 0; slot < count; slot++) {
            AccessibleNode *image = new_component(ATK_ROLE_IMAGE,
                attachmentPending.tiles[slot].name);
            image->id = g_strdup(attachmentPending.tiles[slot].id);
            image->row = slot;
            image->bounds = attachmentPending.tiles[slot].bounds;
            atk_object_set_accessible_id(ATK_OBJECT(image), image->id);
            char label[MAX_ATTACHMENT_NAME + 16];
            snprintf(label, sizeof(label), "Remove %s", attachmentPending.tiles[slot].name);
            AccessibleNode *button = new_component(ATK_ROLE_PUSH_BUTTON, label);
            button->id = g_strdup_printf("linux.%s.attachment.remove.%d",
                scope == 1 ? "composer" : "conversation", slot);
            button->bounds = attachmentPending.tiles[slot].removeBounds;
            atk_object_set_accessible_id(ATK_OBJECT(button), button->id);
            add_child(image, button);
            add_child(attachmentList, image);
            g_object_unref(button);
            g_object_unref(image);
        }
        if (scope == 1) rebuild_placeholder_children();
        else add_child((AccessibleNode *)terminal, attachmentList);
        generation++;
    }
    AtkRectangle unionBounds = attachmentPending.tiles[0].bounds;
    for (int slot = 0; slot < count; slot++) {
        AccessibleNode *image = g_ptr_array_index(attachmentList->children, (guint)slot);
        AccessibleNode *button = g_ptr_array_index(image->children, 0);
        set_name_if_changed(image, attachmentPending.tiles[slot].name);
        char label[MAX_ATTACHMENT_NAME + 16];
        snprintf(label, sizeof(label), "Remove %s", attachmentPending.tiles[slot].name);
        set_name_if_changed(button, label);
        image->bounds = attachmentPending.tiles[slot].bounds;
        button->bounds = attachmentPending.tiles[slot].removeBounds;
        const AtkRectangle bounds = image->bounds;
        const int right = MAX(unionBounds.x + unionBounds.width, bounds.x + bounds.width);
        const int bottom = MAX(unionBounds.y + unionBounds.height, bounds.y + bounds.height);
        unionBounds.x = MIN(unionBounds.x, bounds.x);
        unionBounds.y = MIN(unionBounds.y, bounds.y);
        unionBounds.width = right - unionBounds.x;
        unionBounds.height = bottom - unionBounds.y;
    }
    attachmentList->bounds = unionBounds;
}
int tw_accessibility_attachment_identity(int row, int *scope, char *id, int capacity) {
    if (!bridgeReady || !attachmentScope || !scope || !id || capacity < 37 ||
        row < 0 || (guint)row >= attachmentList->children->len) return 0;
    AccessibleNode *image = g_ptr_array_index(attachmentList->children, (guint)row);
    if (image->retired || !image->id || image->children->len != 1) return 0;
    AccessibleNode *button = g_ptr_array_index(image->children, 0);
    if (attachment_button_slot(button) != row) return 0;
    *scope = attachmentScope;
    strcpy(id, image->id);
    return 1;
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
    if (item->retired || !item->controlTargetID || item->children->len != 2) return 0;
    const guint childIndex = control == PROJECT_CONTROL_CREATE ? 0 : 1;
    AccessibleNode *button = g_ptr_array_index(item->children, childIndex);
    if (button->projectControl != control || button->retired || !button->enabled ||
        button->actionRow != row || !node_mounted(ATK_OBJECT(button))) return 0;
    strcpy(id, item->controlTargetID); // The row API bounded this target to MAX_ROW_ID - 1 bytes.
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
void tw_accessibility_settings_button(TWWindow *window, int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow) return;
    if (!settingsVisible) generation++;
    settingsVisible = 1;
    settingsButton->enabled = 1;
    settingsButton->bounds = (AtkRectangle){x, y, width, height};
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
    if (!visible || strcmp(pageTitleIdentity, identity) != 0) {
        if (pageActionsVisible || openInVisible || sessionMenuVisible) generation++;
        pageActionsVisible = openInVisible = sessionMenuVisible = 0;
        pageActionsIdentity[0] = openInIdentity[0] = sessionMenuIdentity[0] = '\0';
        tw_open_in_shortcut_state(window, NULL, 0);
        clear_children(sessionMenuList);
    }
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
void tw_accessibility_page_actions(TWWindow *window, const char *identity, const char *label,
                                   int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow) return;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    const int sidebarWidth = tw_workspace_sidebar_width(window);
    const int topInset = tw_workspace_terminal_top_inset_value(window);
    const int visible = pageTitleVisible && identity && label &&
        strcmp(identity, pageTitleIdentity) == 0 &&
        strnlen(label, 512) < 512 && g_utf8_validate(label, -1, NULL) &&
        x >= sidebarWidth && x < windowWidth && width > 0 && width <= windowWidth - x &&
        y >= 0 && y < topInset && height > 0 && height <= topInset - y;
    if (pageActionsVisible != visible ||
        (visible && strcmp(pageActionsIdentity, identity) != 0)) generation++;
    pageActionsVisible = visible;
    if (visible) {
        g_strlcpy(pageActionsIdentity, identity, sizeof(pageActionsIdentity));
        set_name_if_changed(pageActionsButton, label);
        pageActionsButton->bounds = (AtkRectangle){x, y, width, height};
    } else pageActionsIdentity[0] = '\0';
    show_content(activeList ? list : (AccessibleNode *)terminal);
}
void tw_accessibility_open_in(TWWindow *window, const char *identity,
                              const char *primaryLabel, const char *chooserLabel, int enabled,
                              int primaryX, int primaryY, int primaryWidth, int primaryHeight,
                              int chooserX, int chooserY, int chooserWidth, int chooserHeight) {
    if (!window) return;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    const int sidebarWidth = tw_workspace_sidebar_width(window);
    const int topInset = tw_workspace_terminal_top_inset_value(window);
    const int primaryValid = primaryX >= sidebarWidth && primaryX < windowWidth &&
        primaryWidth > 0 && primaryWidth <= windowWidth - primaryX &&
        primaryY >= 0 && primaryY < topInset && primaryHeight > 0 &&
        primaryHeight <= topInset - primaryY;
    const int chooserValid = chooserX >= sidebarWidth && chooserX < windowWidth &&
        chooserWidth > 0 && chooserWidth <= windowWidth - chooserX &&
        chooserY >= 0 && chooserY < topInset && chooserHeight > 0 &&
        chooserHeight <= topInset - chooserY;
    const int overlap = primaryValid && chooserValid &&
        primaryX < chooserX + chooserWidth && chooserX < primaryX + primaryWidth &&
        primaryY < chooserY + chooserHeight && chooserY < primaryY + primaryHeight;
    const int valid = sidebarWidth > 0 && identity && identity[0] &&
        primaryLabel && primaryLabel[0] && chooserLabel && chooserLabel[0] &&
        strnlen(identity, sizeof(openInIdentity)) < sizeof(openInIdentity) &&
        strnlen(primaryLabel, 512) < 512 && strnlen(chooserLabel, 512) < 512 &&
        g_utf8_validate(identity, -1, NULL) &&
        g_utf8_validate(primaryLabel, -1, NULL) &&
        g_utf8_validate(chooserLabel, -1, NULL) &&
        primaryValid && chooserValid && !overlap;
    const int active = valid && (!bridgeReady || (pageTitleVisible &&
        strcmp(identity, pageTitleIdentity) == 0));
    tw_open_in_shortcut_state(window, active ? identity : NULL, active && enabled);
    if (!bridgeReady || window != hostWindow) return;
    const int visible = valid && pageTitleVisible &&
        strcmp(identity, pageTitleIdentity) == 0;
    const int nextEnabled = visible && enabled != 0;
    if (openInVisible != visible ||
        (visible && (strcmp(openInIdentity, identity) != 0 ||
                     strcmp(atk_object_get_name(ATK_OBJECT(openInPrimaryButton)), primaryLabel) != 0 ||
                     strcmp(atk_object_get_name(ATK_OBJECT(openInChooserButton)), chooserLabel) != 0)) ||
        openInPrimaryButton->enabled != nextEnabled) generation++;
    openInVisible = visible;
    if (visible) {
        g_strlcpy(openInIdentity, identity, sizeof(openInIdentity));
        set_name_if_changed(openInPrimaryButton, primaryLabel);
        set_name_if_changed(openInChooserButton, chooserLabel);
        openInPrimaryButton->bounds = (AtkRectangle){primaryX, primaryY,
                                                     primaryWidth, primaryHeight};
        openInChooserButton->bounds = (AtkRectangle){chooserX, chooserY,
                                                     chooserWidth, chooserHeight};
    } else openInIdentity[0] = '\0';
    if (openInPrimaryButton->enabled != nextEnabled) {
        openInPrimaryButton->enabled = openInChooserButton->enabled = nextEnabled;
        atk_object_notify_state_change(ATK_OBJECT(openInPrimaryButton), ATK_STATE_ENABLED,
                                       nextEnabled);
        atk_object_notify_state_change(ATK_OBJECT(openInPrimaryButton), ATK_STATE_SENSITIVE,
                                       nextEnabled);
        atk_object_notify_state_change(ATK_OBJECT(openInChooserButton), ATK_STATE_ENABLED,
                                       nextEnabled);
        atk_object_notify_state_change(ATK_OBJECT(openInChooserButton), ATK_STATE_SENSITIVE,
                                       nextEnabled);
    }
    show_content(activeList ? list : (AccessibleNode *)terminal);
}
int tw_accessibility_open_in_identity(int action, char *identity, int capacity) {
    if (!bridgeReady || !openInVisible || sessionMenuVisible || !identity ||
        capacity < (int)sizeof(openInIdentity) ||
        strcmp(openInIdentity, pageTitleIdentity) != 0) return 0;
    AccessibleNode *button = action == 1 ? openInPrimaryButton :
        action == 2 ? openInChooserButton : NULL;
    if (!button || !button->enabled || !node_mounted(ATK_OBJECT(button))) return 0;
    strcpy(identity, openInIdentity);
    return 1;
}
void tw_accessibility_session_menu_begin(TWWindow *window, const char *identity,
                                         int x, int y, int width, int height) {
    sessionMenuPending.count = 0;
    sessionMenuPending.visible = 0;
    sessionMenuPending.identity[0] = '\0';
    g_strlcpy(sessionMenuPending.label, "Session actions",
              sizeof(sessionMenuPending.label));
    if (!bridgeReady || window != hostWindow || !identity || !pageTitleVisible ||
        strcmp(identity, pageTitleIdentity) != 0 ||
        strnlen(identity, sizeof(sessionMenuPending.identity)) >= sizeof(sessionMenuPending.identity)) return;
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    const int sidebarWidth = tw_workspace_sidebar_width(window);
    if (x < sidebarWidth || x >= windowWidth || width < 1 || width > windowWidth - x ||
        y < 0 || y >= windowHeight || height < 1 || height > windowHeight - y) return;
    sessionMenuPending.visible = 1;
    g_strlcpy(sessionMenuPending.identity, identity, sizeof(sessionMenuPending.identity));
    sessionMenuPending.bounds = (AtkRectangle){x, y, width, height};
}
void tw_accessibility_session_menu_label(TWWindow *window, const char *label) {
    if (!bridgeReady || window != hostWindow || !sessionMenuPending.visible || !label) return;
    if (strcmp(label, "Open In applications") == 0)
        g_strlcpy(sessionMenuPending.label, label, sizeof(sessionMenuPending.label));
}
int tw_accessibility_session_menu_add_row(TWWindow *window, const char *id, const char *name,
                                          int selected, int enabled,
                                          int x, int y, int width, int height) {
    if (!bridgeReady) return 0;
    if (window != hostWindow || !sessionMenuPending.visible || !id || !name ||
        sessionMenuPending.count >= MAX_SESSION_MENU_ROWS ||
        strnlen(id, MAX_ROW_ID) >= MAX_ROW_ID ||
        strnlen(name, MAX_ROW_NAME) >= MAX_ROW_NAME || !g_utf8_validate(name, -1, NULL)) return -1;
    AtkRectangle menu = sessionMenuPending.bounds;
    if (x < menu.x || y < menu.y || x >= menu.x + menu.width || y >= menu.y + menu.height ||
        width < 1 || height < 1 || width > menu.x + menu.width - x ||
        height > menu.y + menu.height - y) return -1;
    const int index = sessionMenuPending.count++;
    g_strlcpy(sessionMenuPending.rows[index].id, id, MAX_ROW_ID);
    g_strlcpy(sessionMenuPending.rows[index].name, name, MAX_ROW_NAME);
    sessionMenuPending.rows[index].selected = selected != 0;
    sessionMenuPending.rows[index].enabled = enabled != 0;
    sessionMenuPending.rows[index].bounds = (AtkRectangle){x, y, width, height};
    return 0;
}
void tw_accessibility_session_menu_end(TWWindow *window) {
    if (!bridgeReady || window != hostWindow) return;
    const int visible = sessionMenuPending.visible && sessionMenuPending.count > 0;
    const char *listID = strcmp(sessionMenuPending.label, "Open In applications") == 0
        ? "linux.open-in.choices" : "linux.session-actions";
    int same = visible && sessionMenuVisible &&
        strcmp(sessionMenuIdentity, sessionMenuPending.identity) == 0 &&
        strcmp(atk_object_get_name(ATK_OBJECT(sessionMenuList)), sessionMenuPending.label) == 0 &&
        strcmp(sessionMenuList->id, listID) == 0 &&
        sessionMenuList->children->len == (guint)sessionMenuPending.count;
    for (int i = 0; same && i < sessionMenuPending.count; i++) {
        AccessibleNode *row = g_ptr_array_index(sessionMenuList->children, (guint)i);
        same = row->id && strcmp(row->id, sessionMenuPending.rows[i].id) == 0;
    }
    if (!visible || !same) {
        if (sessionMenuVisible || visible) generation++;
        clear_children(sessionMenuList);
    }
    sessionMenuVisible = visible;
    if (visible) {
        g_strlcpy(sessionMenuIdentity, sessionMenuPending.identity, sizeof(sessionMenuIdentity));
        set_name_if_changed(sessionMenuList, sessionMenuPending.label);
        if (strcmp(sessionMenuList->id, listID) != 0) {
            g_free(sessionMenuList->id);
            sessionMenuList->id = g_strdup(listID);
            atk_object_set_accessible_id(ATK_OBJECT(sessionMenuList), sessionMenuList->id);
        }
        sessionMenuList->bounds = sessionMenuPending.bounds;
        if (!same) {
            for (int i = 0; i < sessionMenuPending.count; i++) {
                AccessibleNode *row = new_component(ATK_ROLE_LIST_ITEM, sessionMenuPending.rows[i].name);
                row->id = g_strdup(sessionMenuPending.rows[i].id);
                atk_object_set_accessible_id(ATK_OBJECT(row), row->id);
                row->row = i;
                row->selected = sessionMenuPending.rows[i].selected;
                row->enabled = sessionMenuPending.rows[i].enabled;
                row->bounds = sessionMenuPending.rows[i].bounds;
                add_child(sessionMenuList, row);
                g_object_unref(row);
            }
        } else {
            for (int i = 0; i < sessionMenuPending.count; i++) {
                AccessibleNode *row = g_ptr_array_index(sessionMenuList->children, (guint)i);
                set_name_if_changed(row, sessionMenuPending.rows[i].name);
                if (row->enabled != sessionMenuPending.rows[i].enabled) {
                    row->enabled = sessionMenuPending.rows[i].enabled;
                    generation++;
                    atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_ENABLED, row->enabled);
                    atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SENSITIVE, row->enabled);
                }
                if (row->selected != sessionMenuPending.rows[i].selected) {
                    row->selected = sessionMenuPending.rows[i].selected;
                    atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SELECTED, row->selected);
                }
                row->bounds = sessionMenuPending.rows[i].bounds;
            }
        }
    } else sessionMenuIdentity[0] = '\0';
    show_content(activeList ? list : (AccessibleNode *)terminal);
    refresh_focus();
}
int tw_accessibility_session_menu_row_identity(int row, char *identity, int capacity) {
    if (!bridgeReady || !sessionMenuVisible || !identity || capacity < (int)sizeof(sessionMenuIdentity) ||
        strcmp(sessionMenuIdentity, pageTitleIdentity) != 0 ||
        row < 0 || (guint)row >= sessionMenuList->children->len) return 0;
    AccessibleNode *item = g_ptr_array_index(sessionMenuList->children, (guint)row);
    if (item->retired || !item->enabled || !node_mounted(ATK_OBJECT(item))) return 0;
    strcpy(identity, sessionMenuIdentity);
    return 1;
}
static int composer_bounds_valid(TWWindow *window, int x, int y, int width, int height) {
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    const int sidebarWidth = tw_workspace_sidebar_width(window);
    return sidebarWidth > 0 && x >= sidebarWidth && x < windowWidth &&
        width > 0 && width <= windowWidth - x && y >= 0 && y < windowHeight &&
        height > 0 && height <= windowHeight - y;
}
static int composer_identity_valid(const char *identity) {
    return identity && identity[0] &&
        strnlen(identity, MAX_COMPOSER_ID) < MAX_COMPOSER_ID &&
        g_utf8_validate(identity, -1, NULL) &&
        strcmp(identity, composerIdentity) == 0;
}
static void rebuild_placeholder_children(void) {
    const int titleVisible = placeholderVisible &&
        atk_object_get_name(ATK_OBJECT(placeholderTitle))[0] != '\0';
    const int detailVisible = placeholderVisible &&
        atk_object_get_name(ATK_OBJECT(placeholderDetail))[0] != '\0';
    const int editorVisible = placeholderVisible && composerEditorVisible;
    const int projectVisible = placeholderVisible && composerChipVisible[0];
    const int providerVisible = placeholderVisible && composerChipVisible[1];
    const int permissionVisible = placeholderVisible && composerChipVisible[2];
    const int modelVisible = placeholderVisible && composerChipVisible[3];
    const int surfaceVisible = placeholderVisible && composerChipVisible[4];
    const int speedVisible = placeholderVisible && composerChipVisible[5];
    const int menuVisible = placeholderVisible && composerMenuVisible;
    const int attachmentsVisible = placeholderVisible && attachmentScope == 1 &&
        attachmentList && attachmentList->children->len > 0;
    const guint expected = placeholderVisible ?
        titleVisible + detailVisible + projectVisible + providerVisible + editorVisible + attachmentsVisible +
        modelVisible + permissionVisible + speedVisible + surfaceVisible +
        placeholderActionVisible + menuVisible : 0;
    int same = placeholder->children->len == expected;
    AccessibleNode *ordered[] = {placeholderTitle, placeholderDetail, composerProjectChip,
        composerProviderChip, (AccessibleNode *)composerEditor, attachmentList,
        composerModelChip, composerPermissionChip,
        composerSpeedChip, composerSurfaceChip, placeholderAction, composerMenuList};
    const int included[] = {titleVisible, detailVisible, projectVisible, providerVisible,
        editorVisible, attachmentsVisible, modelVisible, permissionVisible,
        speedVisible, surfaceVisible, placeholderActionVisible, menuVisible};
    guint index = 0;
    for (guint i = 0; same && i < G_N_ELEMENTS(ordered); i++)
        if (included[i]) same = g_ptr_array_index(placeholder->children, index++) == ordered[i];
    if (same) return;
    if (focused == placeholderAction || focused == (AccessibleNode *)composerEditor ||
        focused == composerProjectChip || focused == composerProviderChip || focused == composerPermissionChip ||
        focused == composerModelChip || focused == composerSurfaceChip || focused == composerSpeedChip ||
        focused == composerMenuList ||
        (focused && atk_object_get_parent(ATK_OBJECT(focused)) == ATK_OBJECT(composerMenuList)))
        set_focused(NULL);
    clear_children(placeholder);
    if (placeholderVisible) {
        if (titleVisible) add_child(placeholder, placeholderTitle);
        if (detailVisible) add_child(placeholder, placeholderDetail);
        if (projectVisible) add_child(placeholder, composerProjectChip);
        if (providerVisible) add_child(placeholder, composerProviderChip);
        if (editorVisible) add_child(placeholder, (AccessibleNode *)composerEditor);
        if (attachmentsVisible) add_child(placeholder, attachmentList);
        if (modelVisible) add_child(placeholder, composerModelChip);
        if (permissionVisible) add_child(placeholder, composerPermissionChip);
        if (speedVisible) add_child(placeholder, composerSpeedChip);
        if (surfaceVisible) add_child(placeholder, composerSurfaceChip);
        if (placeholderActionVisible) add_child(placeholder, placeholderAction);
        if (menuVisible) add_child(placeholder, composerMenuList);
    }
    generation++;
}
static void clear_composer_choice_projection(void) {
    composerFocusKind = -1;
    const int expandedKind = composerMenuVisible ? composerMenuKind : 0;
    if (composerChipVisible[0] || composerChipVisible[1] || composerChipVisible[2] ||
        composerChipVisible[3] || composerChipVisible[4] || composerChipVisible[5] || composerMenuVisible) generation++;
    composerChipVisible[0] = composerChipVisible[1] = composerChipVisible[2] = composerChipVisible[3] = composerChipVisible[4] = composerChipVisible[5] = 0;
    composerMenuVisible = composerMenuKind = 0;
    composerMenuIdentity[0] = '\0';
    if (composerMenuList) clear_children(composerMenuList);
    if (expandedKind)
        atk_object_notify_state_change(ATK_OBJECT(composer_chip(expandedKind)),
                                       ATK_STATE_EXPANDED, FALSE);
}
void tw_accessibility_placeholder(TWWindow *window, const char *title, const char *detail,
                                   const char *actionLabel, int actionEnabled,
                                   int x, int y, int width, int height) {
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
    if (!visible && composerEditorVisible) {
        clear_composer_edits();
        composerIdentity[0] = '\0';
        composerEditorVisible = composerEditorFocused = 0;
        atk_object_notify_state_change(ATK_OBJECT(composerEditor), ATK_STATE_EDITABLE, FALSE);
        set_composer_text("", 0, 0, 0, 0);
    }
    if (!visible) {
        clear_composer_choice_projection();
        clear_attachment_projection();
    }
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
            if (placeholderAction->enabled != (actionEnabled != 0)) {
                placeholderAction->enabled = actionEnabled != 0;
                atk_object_notify_state_change(ATK_OBJECT(placeholderAction),
                                               ATK_STATE_ENABLED, placeholderAction->enabled);
            }
        }
    }
    rebuild_placeholder_children();
    show_content(activeList ? list : (placeholderVisible ? placeholder : (AccessibleNode *)terminal));
    refresh_focus();
}
void tw_accessibility_placeholder_heading_bounds(TWWindow *window,
                                                 int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow || !placeholderVisible) return;
    placeholderTitle->bounds = (AtkRectangle){x, y, width, height};
}
void tw_accessibility_composer_editor(TWWindow *window, const char *identity,
                                      const char *utf8, int length,
                                      int selectionStart, int selectionEnd, int hasFocus,
                                      int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow || !placeholderVisible) return;
    if (!utf8) {
        if (!composerEditorVisible) return;
        clear_composer_edits();
        composerIdentity[0] = '\0';
        composerEditorVisible = composerEditorFocused = 0;
        atk_object_notify_state_change(ATK_OBJECT(composerEditor), ATK_STATE_EDITABLE, FALSE);
        set_composer_text("", 0, 0, 0, 0);
        clear_composer_choice_projection();
        rebuild_placeholder_children();
        refresh_focus();
        return;
    }
    int originX, originY, windowWidth, windowHeight;
    tw_window_geometry(window, &originX, &originY, &windowWidth, &windowHeight);
    const int sidebarWidth = tw_workspace_sidebar_width(window);
    if (!identity || !identity[0] || strnlen(identity, MAX_COMPOSER_ID) >= MAX_COMPOSER_ID ||
        !g_utf8_validate(identity, -1, NULL) ||
        length < 0 || length > MAX_COMPOSER_TEXT ||
        memchr(utf8, 0, (size_t)length) || !g_utf8_validate(utf8, length, NULL) ||
        x < sidebarWidth || x >= windowWidth || width <= 0 || width > windowWidth - x ||
        y < 0 || y >= windowHeight || height <= 0 || height > windowHeight - y) return;
    const int characters = (int)g_utf8_strlen(utf8, length);
    if (selectionStart < 0 || selectionStart > selectionEnd || selectionEnd > characters) return;
    if (strcmp(composerIdentity, identity) != 0) {
        clear_composer_edits();
        g_strlcpy(composerIdentity, identity, sizeof(composerIdentity));
        clear_composer_choice_projection();
        generation++;
    }
    if (g_queue_is_empty(composerEdits)) {
        composerPredictedCharacters = characters;
        composerPredictionValid = 1;
    }
    const int wasVisible = composerEditorVisible;
    composerEditorVisible = 1;
    composerEditorFocused = hasFocus != 0;
    ((AccessibleNode *)composerEditor)->bounds = (AtkRectangle){x, y, width, height};
    set_composer_text(utf8, length, characters, selectionStart, selectionEnd);
    rebuild_placeholder_children();
    if (!wasVisible) atk_object_notify_state_change(ATK_OBJECT(composerEditor), ATK_STATE_EDITABLE, TRUE);
    refresh_focus();
}
void tw_accessibility_text_prompt(TWWindow *window, const char *identity, const char *fieldID,
                                  const char *fieldLabel, const char *fieldDescription,
                                  const char *title, const char *message,
                                  const char *confirmTitle, const char *clearTitle,
                                  const char *suppressionTitle, int suppressionChecked,
                                  const char *value, int length,
                                  int selectionStart, int selectionEnd, int focusKind,
                                  int titleX, int titleY, int titleWidth, int titleHeight,
                                  int messageX, int messageY, int messageWidth, int messageHeight,
                                  int fieldX, int fieldY, int fieldWidth, int fieldHeight,
                                  int cancelX, int cancelY, int cancelWidth, int cancelHeight,
                                  int createX, int createY, int createWidth, int createHeight,
                                  int clearX, int clearY, int clearWidth, int clearHeight,
                                  int suppressionX, int suppressionY,
                                  int suppressionWidth, int suppressionHeight) {
    if (!bridgeReady || window != hostWindow || !identity || !fieldID || !fieldLabel ||
        !fieldDescription || !title || !message || !confirmTitle || !clearTitle ||
        !suppressionTitle || !value ||
        strnlen(identity, MAX_COMPOSER_ID) >= MAX_COMPOSER_ID ||
        strnlen(fieldID, MAX_COMPOSER_ID) >= MAX_COMPOSER_ID ||
        strnlen(fieldLabel, 512) >= 512 || strnlen(fieldDescription, 512) >= 512 ||
        strnlen(title, 512) >= 512 || strnlen(message, 512) >= 512 ||
        strnlen(confirmTitle, 512) >= 512 || strnlen(clearTitle, 512) >= 512 ||
        strnlen(suppressionTitle, 512) >= 512 ||
        !g_utf8_validate(identity, -1, NULL) || !g_utf8_validate(fieldID, -1, NULL) ||
        !g_utf8_validate(fieldLabel, -1, NULL) ||
        !g_utf8_validate(fieldDescription, -1, NULL) ||
        !g_utf8_validate(title, -1, NULL) || !g_utf8_validate(message, -1, NULL) ||
        !g_utf8_validate(confirmTitle, -1, NULL) || !g_utf8_validate(clearTitle, -1, NULL) ||
        !g_utf8_validate(suppressionTitle, -1, NULL) ||
        length < 0 || length > 4096 || memchr(value, 0, (size_t)length) ||
        !g_utf8_validate(value, length, NULL) || focusKind < 0 || focusKind > 4 ||
        (suppressionChecked != 0 && suppressionChecked != 1)) return;
    int originX, originY, width, height;
    tw_window_geometry(window, &originX, &originY, &width, &height);
    const int hasField = fieldID[0] != '\0';
    const int rectangles[] = {titleX, titleY, titleWidth, titleHeight,
        cancelX, cancelY, cancelWidth, cancelHeight,
        createX, createY, createWidth, createHeight};
    for (int index = 0; index < 12; index += 4) {
        if (rectangles[index] < 0 || rectangles[index + 1] < 0 ||
            rectangles[index + 2] <= 0 || rectangles[index + 3] <= 0 ||
            rectangles[index] > width - rectangles[index + 2] ||
            rectangles[index + 1] > height - rectangles[index + 3]) return;
    }
    if (hasField && (fieldX < 0 || fieldY < 0 || fieldWidth <= 0 || fieldHeight <= 0 ||
        fieldX > width - fieldWidth || fieldY > height - fieldHeight)) return;
    if (message[0] && (messageX < 0 || messageY < 0 || messageWidth <= 0 ||
        messageHeight <= 0 || messageX > width - messageWidth ||
        messageY > height - messageHeight)) return;
    if (clearTitle[0] && (clearX < 0 || clearY < 0 || clearWidth <= 0 ||
        clearHeight <= 0 || clearX > width - clearWidth ||
        clearY > height - clearHeight)) return;
    if (suppressionTitle[0] && (suppressionX < 0 || suppressionY < 0 ||
        suppressionWidth <= 0 || suppressionHeight <= 0 ||
        suppressionX > width - suppressionWidth ||
        suppressionY > height - suppressionHeight)) return;
    const int characters = (int)g_utf8_strlen(value, length);
    if (selectionStart < 0 || selectionStart > selectionEnd || selectionEnd > characters) return;

    if (!promptVisible) {
        clear_composer_edits();
        g_strlcpy(composerIdentity, identity, sizeof(composerIdentity));
        atk_object_set_role(ATK_OBJECT(composerEditor), ATK_ROLE_ENTRY);
        atk_object_set_name(ATK_OBJECT(composerEditor), fieldLabel);
        atk_object_set_description(ATK_OBJECT(composerEditor), fieldDescription);
        g_free(((AccessibleNode *)composerEditor)->id);
        ((AccessibleNode *)composerEditor)->id = g_strdup(fieldID);
        atk_object_set_accessible_id(ATK_OBJECT(composerEditor),
                                     ((AccessibleNode *)composerEditor)->id);
        g_free(promptPanel->id);
        promptPanel->id = g_strdup(identity);
        atk_object_set_accessible_id(ATK_OBJECT(promptPanel), promptPanel->id);
        clear_children(promptPanel);
        add_child(promptPanel, promptTitle);
        if (message[0]) add_child(promptPanel, promptMessage);
        if (hasField) add_child(promptPanel, (AccessibleNode *)composerEditor);
        if (suppressionTitle[0]) add_child(promptPanel, promptSuppression);
        add_child(promptPanel, promptCancel);
        if (clearTitle[0]) add_child(promptPanel, promptClear);
        add_child(promptPanel, promptCreate);
        promptVisible = 1;
        composerEditorVisible = hasField;
        generation++;
    }
    set_name_if_changed(promptPanel, title);
    set_name_if_changed(promptTitle, title);
    set_name_if_changed(promptMessage, message);
    set_name_if_changed(promptCreate, confirmTitle);
    if (clearTitle[0]) set_name_if_changed(promptClear, clearTitle);
    if (suppressionTitle[0]) set_name_if_changed(promptSuppression, suppressionTitle);
    promptPanel->bounds = (AtkRectangle){0, 0, width, height};
    promptTitle->bounds = (AtkRectangle){titleX, titleY, titleWidth, titleHeight};
    promptMessage->bounds = (AtkRectangle){messageX, messageY, messageWidth, messageHeight};
    if (hasField) ((AccessibleNode *)composerEditor)->bounds = (AtkRectangle){fieldX, fieldY,
                                                              fieldWidth, fieldHeight};
    promptCancel->bounds = (AtkRectangle){cancelX, cancelY, cancelWidth, cancelHeight};
    promptCreate->bounds = (AtkRectangle){createX, createY, createWidth, createHeight};
    promptClear->bounds = (AtkRectangle){clearX, clearY, clearWidth, clearHeight};
    promptSuppression->bounds = (AtkRectangle){suppressionX, suppressionY,
                                              suppressionWidth, suppressionHeight};
    if (promptSuppression->selected != suppressionChecked) {
        promptSuppression->selected = suppressionChecked;
        atk_object_notify_state_change(ATK_OBJECT(promptSuppression), ATK_STATE_CHECKED,
                                       suppressionChecked);
    }
    if (hasField && g_queue_is_empty(composerEdits)) {
        composerPredictedCharacters = characters;
        composerPredictionValid = 1;
    }
    if (hasField) set_composer_text(value, length, characters, selectionStart, selectionEnd);
    promptFocusKind = focusKind;
    composerEditorFocused = focusKind == 0;
    show_content(promptPanel);
    refresh_focus();
}
void tw_accessibility_composer_chip(TWWindow *window, const char *identity, int kind,
                                    const char *label, const char *value,
                                    int enabled, int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow || (kind < 1 || kind > 6)) return;
    AccessibleNode *chip = composer_chip(kind);
    const int visible = placeholderVisible && composerEditorVisible &&
        composer_identity_valid(identity) && label && value &&
        strnlen(label, MAX_ROW_NAME) < MAX_ROW_NAME &&
        strnlen(value, MAX_ROW_NAME) < MAX_ROW_NAME &&
        g_utf8_validate(label, -1, NULL) && g_utf8_validate(value, -1, NULL) &&
        composer_bounds_valid(window, x, y, width, height);
    if (composerChipVisible[kind - 1] != visible) generation++;
    composerChipVisible[kind - 1] = visible;
    const int nextEnabled = visible && enabled;
    if (chip->enabled != nextEnabled) {
        chip->enabled = nextEnabled;
        generation++;
        atk_object_notify_state_change(ATK_OBJECT(chip), ATK_STATE_ENABLED, nextEnabled);
        atk_object_notify_state_change(ATK_OBJECT(chip), ATK_STATE_SENSITIVE, nextEnabled);
    }
    if (visible) {
        char name[MAX_ROW_NAME * 2 + 3];
        g_snprintf(name, sizeof(name), "%s: %s", label, value);
        if (strcmp(atk_object_get_name(ATK_OBJECT(chip)), name) != 0) generation++;
        set_name_if_changed(chip, name);
        chip->bounds = (AtkRectangle){x, y, width, height};
    }
    rebuild_placeholder_children();
    refresh_focus();
}
void tw_accessibility_composer_focus(TWWindow *window, const char *identity, int kind) {
    if (!bridgeReady || window != hostWindow || !composerEditorVisible ||
        !composer_identity_valid(identity) || kind < 0 || kind > 8) return;
    composerFocusKind = kind;
    refresh_focus();
}
void tw_accessibility_composer_menu_begin(TWWindow *window, const char *identity, int kind,
                                          int x, int y, int width, int height) {
    composerMenuPending.count = composerMenuPending.visible = composerMenuPending.kind = 0;
    composerMenuPending.identity[0] = '\0';
    if (!bridgeReady || window != hostWindow || !placeholderVisible ||
        !composerEditorVisible || (kind < 1 || kind > 6) ||
        !composerChipVisible[kind - 1] || !composer_identity_valid(identity) ||
        !composer_bounds_valid(window, x, y, width, height)) return;
    composerMenuPending.visible = 1;
    composerMenuPending.kind = kind;
    composerMenuPending.bounds = (AtkRectangle){x, y, width, height};
    g_strlcpy(composerMenuPending.identity, identity, sizeof(composerMenuPending.identity));
}
int tw_accessibility_composer_menu_add_row(TWWindow *window, int optionIndex,
                                           const char *id, const char *name, const char *description,
                                           int selected, int enabled, int highlighted,
                                           int x, int y, int width, int height) {
    if (!bridgeReady) return 0;
    if (window != hostWindow || !composerMenuPending.visible ||
        composerMenuPending.count >= (composerMenuPending.kind == 4 ? MAX_COMPOSER_MENU_ROWS : 6) ||
        (optionIndex < 0 && !(composerMenuPending.kind == 4 && optionIndex == -1)) ||
        !id || !id[0] || !name || !description ||
        strnlen(description, MAX_ROW_NAME) >= MAX_ROW_NAME || !g_utf8_validate(description, -1, NULL) ||
        strnlen(id, MAX_ROW_ID) >= MAX_ROW_ID ||
        strnlen(name, MAX_ROW_NAME) >= MAX_ROW_NAME ||
        !g_utf8_validate(id, -1, NULL) || !g_utf8_validate(name, -1, NULL)) return -1;
    const AtkRectangle menu = composerMenuPending.bounds;
    if (x < menu.x || y < menu.y || x >= menu.x + menu.width || y >= menu.y + menu.height ||
        width <= 0 || width > menu.x + menu.width - x ||
        height <= 0 || height > menu.y + menu.height - y) return -1;
    const int slot = composerMenuPending.count++;
    g_strlcpy(composerMenuPending.rows[slot].id, id, MAX_ROW_ID);
    g_strlcpy(composerMenuPending.rows[slot].name, name, MAX_ROW_NAME);
    g_strlcpy(composerMenuPending.rows[slot].description, description, MAX_ROW_NAME);
    composerMenuPending.rows[slot].optionIndex = optionIndex;
    composerMenuPending.rows[slot].selected = selected != 0;
    composerMenuPending.rows[slot].enabled = enabled != 0;
    composerMenuPending.rows[slot].highlighted = highlighted != 0;
    composerMenuPending.rows[slot].bounds = (AtkRectangle){x, y, width, height};
    return 0;
}
void tw_accessibility_composer_menu_end(TWWindow *window) {
    if (!bridgeReady || window != hostWindow) return;
    const int visible = composerMenuPending.visible && composerMenuPending.count > 0;
    const int previousKind = composerMenuVisible ? composerMenuKind : 0;
    int same = visible && composerMenuVisible &&
        composerMenuKind == composerMenuPending.kind &&
        strcmp(composerMenuIdentity, composerMenuPending.identity) == 0 &&
        composerMenuList->children->len == (guint)composerMenuPending.count;
    for (int i = 0; same && i < composerMenuPending.count; i++) {
        AccessibleNode *row = g_ptr_array_index(composerMenuList->children, (guint)i);
        same = row->id && strcmp(row->id, composerMenuPending.rows[i].id) == 0 &&
            row->row == i && row->optionIndex == composerMenuPending.rows[i].optionIndex;
    }
    if (!visible || !same) {
        if (composerMenuVisible || visible) generation++;
        clear_children(composerMenuList);
    }
    composerMenuVisible = visible;
    if (visible) {
        composerMenuKind = composerMenuPending.kind;
        g_strlcpy(composerMenuIdentity, composerMenuPending.identity, sizeof(composerMenuIdentity));
        composerMenuList->bounds = composerMenuPending.bounds;
        set_name_if_changed(composerMenuList, composerMenuKind == 1 ? "Projects"
            : composerMenuKind == 2 ? "Providers" : composerMenuKind == 3 ? "Permissions"
            : composerMenuKind == 4 ? "Model and effort"
            : composerMenuKind == 5 ? "Interface" : "Speed");
        atk_object_set_role(ATK_OBJECT(composerMenuList), composerMenuKind == 4 ? ATK_ROLE_PANEL : ATK_ROLE_LIST);
        if (!same) {
            for (int i = 0; i < composerMenuPending.count; i++) {
                const AtkRole role = composerMenuPending.rows[i].optionIndex == -1
                    ? ATK_ROLE_PUSH_BUTTON
                    : (composerMenuKind == 4 ? ATK_ROLE_RADIO_BUTTON : ATK_ROLE_LIST_ITEM);
                AccessibleNode *row = new_component(role, composerMenuPending.rows[i].name);
                row->id = g_strdup(composerMenuPending.rows[i].id);
                atk_object_set_accessible_id(ATK_OBJECT(row), role == ATK_ROLE_PUSH_BUTTON
                    ? "model-effort.show-hidden-models" : row->id);
                row->row = i;
                row->optionIndex = composerMenuPending.rows[i].optionIndex;
                atk_object_set_description(ATK_OBJECT(row), composerMenuPending.rows[i].description);
                row->selected = composerMenuPending.rows[i].selected;
                row->enabled = composerMenuPending.rows[i].enabled;
                row->highlighted = composerMenuPending.rows[i].highlighted;
                row->bounds = composerMenuPending.rows[i].bounds;
                add_child(composerMenuList, row);
                g_object_unref(row);
            }
        } else {
            for (int i = 0; i < composerMenuPending.count; i++) {
                AccessibleNode *row = g_ptr_array_index(composerMenuList->children, (guint)i);
                set_name_if_changed(row, composerMenuPending.rows[i].name);
                row->highlighted = composerMenuPending.rows[i].highlighted;
                atk_object_set_description(ATK_OBJECT(row), composerMenuPending.rows[i].description);
                if (row->selected != composerMenuPending.rows[i].selected) {
                    row->selected = composerMenuPending.rows[i].selected;
                    atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SELECTED, row->selected);
                    if (composerMenuKind == 4)
                        atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_CHECKED, row->selected);
                }
                if (row->enabled != composerMenuPending.rows[i].enabled) {
                    row->enabled = composerMenuPending.rows[i].enabled;
                    generation++;
                    atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_ENABLED, row->enabled);
                    atk_object_notify_state_change(ATK_OBJECT(row), ATK_STATE_SENSITIVE, row->enabled);
                }
                row->bounds = composerMenuPending.rows[i].bounds;
            }
        }
    } else {
        composerMenuKind = 0;
        composerMenuIdentity[0] = '\0';
    }
    const int currentKind = composerMenuVisible ? composerMenuKind : 0;
    if (previousKind != currentKind) {
        if (previousKind)
            atk_object_notify_state_change(ATK_OBJECT(composer_chip(previousKind)),
                                           ATK_STATE_EXPANDED, FALSE);
        if (currentKind)
            atk_object_notify_state_change(ATK_OBJECT(composer_chip(currentKind)),
                                           ATK_STATE_EXPANDED, TRUE);
    }
    rebuild_placeholder_children();
    refresh_focus();
}
int tw_accessibility_composer_chip_identity(int kind, char *identity, int capacity) {
    if (!bridgeReady || (kind < 1 || kind > 6) || !identity || capacity < MAX_COMPOSER_ID ||
        !placeholderVisible || !composerEditorVisible || !composerChipVisible[kind - 1] ||
        !composerIdentity[0]) return 0;
    AccessibleNode *chip = composer_chip(kind);
    if (!node_mounted(ATK_OBJECT(chip))) return 0;
    strcpy(identity, composerIdentity);
    return 1;
}
int tw_accessibility_composer_menu_row_identity(int slot, int *kind,
                                                 int *optionIndex, char *id, int capacity) {
    if (!bridgeReady || !composerMenuVisible || !kind || !optionIndex || !id ||
        capacity < MAX_ROW_ID || !composerIdentity[0] ||
        strcmp(composerMenuIdentity, composerIdentity) != 0 ||
        slot < 0 || (guint)slot >= composerMenuList->children->len) return 0;
    AccessibleNode *row = g_ptr_array_index(composerMenuList->children, (guint)slot);
    if (row->retired || !row->enabled || !node_mounted(ATK_OBJECT(row)) ||
        !row->id || (row->optionIndex < 0 && !(composerMenuKind == 4 && row->optionIndex == -1))) return 0;
    *kind = composerMenuKind;
    *optionIndex = row->optionIndex;
    strcpy(id, row->id);
    return 1;
}
int tw_accessibility_composer_edit_pending(TWWindow *window, uint32_t serial,
                                            uint32_t incarnation) {
    if (!bridgeReady || window != hostWindow || !composerEditorVisible || !composerEdits ||
        incarnation != composerIncarnation || !composerIdentity[0]) return 0;
    ComposerEdit *edit = g_queue_peek_head(composerEdits);
    return edit && edit->serial == serial && edit->incarnation == incarnation &&
        strcmp(edit->identity, composerIdentity) == 0;
}
int tw_accessibility_take_composer_edit(TWWindow *window, int serial, int *operation,
                                        int *start, int *end, char *identity,
                                        int identityCapacity, char *utf8, int textCapacity) {
    if (!tw_accessibility_composer_edit_pending(window, (uint32_t)serial, composerIncarnation) ||
        !operation || !start || !end || !identity || identityCapacity < MAX_COMPOSER_ID ||
        !utf8 || textCapacity < MAX_COMPOSER_TEXT + 1) return -1;
    ComposerEdit *edit = g_queue_pop_head(composerEdits);
    *operation = edit->operation;
    *start = edit->start;
    *end = edit->end;
    strcpy(identity, edit->identity);
    memcpy(utf8, edit->text, (size_t)edit->length + 1);
    const int length = edit->length;
    free_composer_edit(edit);
    return length;
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
    if (tw_workspace_sidebar_width(window) && !tw_navigator_menu_visible(window))
        windowWidth = tw_workspace_sidebar_width(window);
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
    pending.rows[index].controlTargetID[0] = '\0';
    pending.rows[index].controlsEnabled = 0;
    pending.rows[index].bounds = (AtkRectangle){x, y, width, height};
    return 0;
}
static int add_project_row_for_target(TWWindow *window, const char *id, const char *targetID,
                                      const char *name, int selected,
                                      int x, int y, int width, int height,
                                      int createX, int createY, int createWidth, int createHeight,
                                      int actionsX, int actionsY, int actionsWidth, int actionsHeight,
                                      int controlsEnabled) {
    const int index = pending.count;
    if (tw_accessibility_add_row(window, id, name, selected, x, y, width, height) != 0) return -1;
    if (!bridgeReady) return 0;
    if (pending.count != index + 1 ||
        !targetID || strnlen(targetID, MAX_ROW_ID) == MAX_ROW_ID ||
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
    strcpy(pending.rows[index].controlTargetID, targetID);
    pending.rows[index].controlsEnabled = controlsEnabled != 0;
    pending.rows[index].createBounds = (AtkRectangle){createX, createY, createWidth, createHeight};
    pending.rows[index].actionsBounds = (AtkRectangle){actionsX, actionsY, actionsWidth, actionsHeight};
    return 0;
}
int tw_accessibility_add_project_row(TWWindow *window, const char *id, const char *name, int selected,
                                     int x, int y, int width, int height,
                                     int createX, int createY, int createWidth, int createHeight,
                                     int actionsX, int actionsY, int actionsWidth, int actionsHeight,
                                     int controlsEnabled) {
    return add_project_row_for_target(window, id, id, name, selected, x, y, width, height,
                                      createX, createY, createWidth, createHeight,
                                      actionsX, actionsY, actionsWidth, actionsHeight,
                                      controlsEnabled);
}
int tw_accessibility_add_repository_row(TWWindow *window, const char *id, const char *projectID,
                                        const char *name, int selected,
                                        int x, int y, int width, int height,
                                        int createX, int createY, int createWidth, int createHeight,
                                        int actionsX, int actionsY, int actionsWidth, int actionsHeight,
                                        int controlsEnabled) {
    return add_project_row_for_target(window, id, projectID, name, selected, x, y, width, height,
                                      createX, createY, createWidth, createHeight,
                                      actionsX, actionsY, actionsWidth, actionsHeight,
                                      controlsEnabled);
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
    const char *label = control == PROJECT_CONTROL_ACTIONS ? "Project actions"
        : g_str_has_prefix(row->id, "repository:")
            ? "New chat, terminal, or worktree" : "New chat or terminal";
    AccessibleNode *button = new_component(ATK_ROLE_PUSH_BUTTON,
        label);
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
void tw_accessibility_empty_list_message(TWWindow *window, const char *message) {
    (void)window;
    if (!bridgeReady || list->children->len || !message || strnlen(message, 512) == 512) return;
    set_description_if_changed(list, message);
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
            if (pending.rows[i].hasProjectControls)
                row->controlTargetID = g_strdup(pending.rows[i].controlTargetID);
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
            if (pending.rows[i].hasProjectControls &&
                (!row->controlTargetID || strcmp(row->controlTargetID,
                                                 pending.rows[i].controlTargetID) != 0)) {
                g_free(row->controlTargetID);
                row->controlTargetID = g_strdup(pending.rows[i].controlTargetID);
            }
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
static void clear_conversation_speed(void) {
    if (!conversationSpeedVisible && !conversationSpeedMenuVisible) return;
    clear_children(conversationSpeedMenu);
    remove_child((AccessibleNode *)terminal, conversationSpeedMenu);
    remove_child((AccessibleNode *)terminal, conversationSpeedChip);
    conversationSpeedVisible = conversationSpeedMenuVisible = conversationSpeedFocused = 0;
    conversationSpeedIdentity[0] = '\0';
    generation++;
    refresh_focus();
}
void tw_accessibility_conversation_speed(TWWindow *window, const char *identity,
                                          const char *title, int enabled, int hasFocus,
                                          int x, int y, int width, int height,
                                          int menuX, int menuY, int menuWidth, int menuHeight,
                                          int selected, int highlighted) {
    if (!bridgeReady || window != hostWindow) return;
    if (!identity || !title || !identity[0] ||
        strnlen(identity, MAX_COMPOSER_ID) >= MAX_COMPOSER_ID ||
        !g_utf8_validate(identity, -1, NULL) ||
        !composer_bounds_valid(window, x, y, width, height)) {
        clear_conversation_speed();
        return;
    }
    const int menuVisible = menuWidth > 0 && menuHeight > 0 &&
        composer_bounds_valid(window, menuX, menuY, menuWidth, menuHeight);
    const int changedIdentity = strcmp(conversationSpeedIdentity, identity) != 0;
    if (changedIdentity || !conversationSpeedVisible ||
        menuVisible != conversationSpeedMenuVisible) {
        clear_children(conversationSpeedMenu);
        remove_child((AccessibleNode *)terminal, conversationSpeedMenu);
        remove_child((AccessibleNode *)terminal, conversationSpeedChip);
        g_strlcpy(conversationSpeedIdentity, identity, sizeof(conversationSpeedIdentity));
        add_child((AccessibleNode *)terminal, conversationSpeedChip);
        if (menuVisible) {
            add_child((AccessibleNode *)terminal, conversationSpeedMenu);
            const char *names[] = {"Follow Agent Setting", "Standard", "Fast"};
            const char *details[] = {"Applies the next time this chat starts.",
                                     "Normal speed and usage", "1.5x speed, increased usage"};
            for (int index = 0; index < 3; index++) {
                AccessibleNode *row = new_component(ATK_ROLE_LIST_ITEM, names[index]);
                char id[64];
                snprintf(id, sizeof(id), "linux.conversation.speed.option.%d", index);
                row->id = g_strdup(id);
                atk_object_set_accessible_id(ATK_OBJECT(row), row->id);
                set_description_if_changed(row, details[index]);
                row->row = index;
                add_child(conversationSpeedMenu, row);
                g_object_unref(row);
            }
        }
        generation++;
    }
    conversationSpeedVisible = 1;
    conversationSpeedMenuVisible = menuVisible;
    conversationSpeedFocused = hasFocus != 0;
    char label[256];
    snprintf(label, sizeof(label), "Speed: %.220s", title);
    set_name_if_changed(conversationSpeedChip, label);
    if (conversationSpeedChip->enabled != (enabled != 0)) {
        conversationSpeedChip->enabled = enabled != 0;
        generation++;
        atk_object_notify_state_change(ATK_OBJECT(conversationSpeedChip), ATK_STATE_ENABLED,
                                       conversationSpeedChip->enabled);
        atk_object_notify_state_change(ATK_OBJECT(conversationSpeedChip), ATK_STATE_SENSITIVE,
                                       conversationSpeedChip->enabled);
    }
    conversationSpeedChip->bounds = (AtkRectangle){x, y, width, height};
    if (menuVisible) {
        conversationSpeedMenu->bounds = (AtkRectangle){menuX, menuY, menuWidth, menuHeight};
        int rowHeight = (menuHeight - 12) / 3;
        for (int index = 0; index < 3; index++) {
            AccessibleNode *row = g_ptr_array_index(conversationSpeedMenu->children, index);
            row->bounds = (AtkRectangle){menuX + 6, menuY + 6 + index * rowHeight,
                                          menuWidth - 12, rowHeight};
            row->selected = index == selected;
            row->highlighted = index == highlighted;
        }
    }
    refresh_focus();
}
int tw_accessibility_conversation_speed_identity(int row, char *identity, int capacity) {
    if (!bridgeReady || !conversationSpeedVisible || !identity || capacity < MAX_COMPOSER_ID ||
        !conversationSpeedIdentity[0] || !conversationSpeedChip->enabled ||
        !node_mounted(ATK_OBJECT(conversationSpeedChip))) return 0;
    if (row >= 0 && (!conversationSpeedMenuVisible || row >= 3 ||
                     !node_mounted(ATK_OBJECT(conversationSpeedMenu)))) return 0;
    strcpy(identity, conversationSpeedIdentity);
    return 1;
}
static void clear_conversation_configuration(void) {
    if (!conversationConfigurationVisible[0] && !conversationConfigurationVisible[1] &&
        !conversationConfigurationVisible[2] &&
        !conversationConfigurationMenuKind) return;
    clear_children(conversationConfigurationMenu);
    remove_child((AccessibleNode *)terminal, conversationConfigurationMenu);
    for (int index = 0; index < 3; index++) {
        remove_child((AccessibleNode *)terminal, conversationConfigurationChips[index]);
        conversationConfigurationVisible[index] = 0;
        conversationConfigurationFocused[index] = 0;
    }
    conversationConfigurationIdentity[0] = '\0';
    conversationConfigurationMenuKind = conversationConfigurationFirst = 0;
    generation++;
    refresh_focus();
}
void tw_accessibility_conversation_configuration_chip(TWWindow *window, const char *identity,
    int kind, const char *title, int enabled, int hasFocus,
    int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow || kind < 1 || kind > 3) return;
    const int index = kind - 1;
    if (!identity || !title || !identity[0] ||
        strnlen(identity, MAX_COMPOSER_ID) >= MAX_COMPOSER_ID ||
        !g_utf8_validate(identity, -1, NULL) ||
        !composer_bounds_valid(window, x, y, width, height)) {
        if (conversationConfigurationVisible[index]) {
            remove_child((AccessibleNode *)terminal, conversationConfigurationChips[index]);
            conversationConfigurationVisible[index] = 0;
            generation++;
        }
        if (conversationConfigurationMenuKind == kind) {
            clear_children(conversationConfigurationMenu);
            remove_child((AccessibleNode *)terminal, conversationConfigurationMenu);
            conversationConfigurationMenuKind = 0;
            generation++;
        }
        refresh_focus();
        return;
    }
    if (conversationConfigurationIdentity[0] &&
        strcmp(conversationConfigurationIdentity, identity) != 0)
        clear_conversation_configuration();
    g_strlcpy(conversationConfigurationIdentity, identity,
        sizeof(conversationConfigurationIdentity));
    AccessibleNode *chip = conversationConfigurationChips[index];
    if (!conversationConfigurationVisible[index]) {
        add_child((AccessibleNode *)terminal, chip);
        conversationConfigurationVisible[index] = 1;
        generation++;
    }
    char label[256];
    snprintf(label, sizeof(label), "%s: %.220s", kind == 1 ? "Model" : kind == 2 ? "Effort" : "Mode", title);
    set_name_if_changed(chip, label);
    if (chip->enabled != (enabled != 0)) {
        chip->enabled = enabled != 0;
        generation++;
        atk_object_notify_state_change(ATK_OBJECT(chip), ATK_STATE_ENABLED, chip->enabled);
        atk_object_notify_state_change(ATK_OBJECT(chip), ATK_STATE_SENSITIVE, chip->enabled);
    }
    chip->bounds = (AtkRectangle){x, y, width, height};
    conversationConfigurationFocused[index] = hasFocus != 0;
    refresh_focus();
}
void tw_accessibility_conversation_configuration_menu(TWWindow *window, const char *identity,
    int kind, int x, int y, int width, int height, int first) {
    if (!bridgeReady || window != hostWindow) return;
    const int visible = kind >= 1 && kind <= 3 && identity &&
        strcmp(conversationConfigurationIdentity, identity) == 0 &&
        conversationConfigurationVisible[kind - 1] &&
        composer_bounds_valid(window, x, y, width, height);
    if (!visible) {
        if (conversationConfigurationMenuKind) {
            clear_children(conversationConfigurationMenu);
            remove_child((AccessibleNode *)terminal, conversationConfigurationMenu);
            conversationConfigurationMenuKind = 0;
            generation++;
            refresh_focus();
        }
        return;
    }
    if (conversationConfigurationMenuKind != kind) {
        remove_child((AccessibleNode *)terminal, conversationConfigurationMenu);
        add_child((AccessibleNode *)terminal, conversationConfigurationMenu);
    }
    clear_children(conversationConfigurationMenu);
    conversationConfigurationMenuKind = kind;
    conversationConfigurationFirst = first;
    conversationConfigurationMenu->bounds = (AtkRectangle){x, y, width, height};
    const char *name = kind == 1 ? "Model choices" : kind == 2 ? "Effort choices" : "Mode choices";
    set_name_if_changed(conversationConfigurationMenu, name);
    char id[64];
    snprintf(id, sizeof(id), "linux.conversation.%s.choices", kind == 1 ? "model" : kind == 2 ? "effort" : "mode");
    g_free(conversationConfigurationMenu->id);
    conversationConfigurationMenu->id = g_strdup(id);
    atk_object_set_accessible_id(ATK_OBJECT(conversationConfigurationMenu),
        conversationConfigurationMenu->id);
    generation++;
}
void tw_accessibility_conversation_configuration_row(TWWindow *window, int index,
    const char *title, const char *detail, int selected, int enabled, int highlighted,
    int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow || !conversationConfigurationMenuKind ||
        !title || index < conversationConfigurationFirst ||
        index >= conversationConfigurationFirst + 6 ||
        conversationConfigurationMenu->children->len >= 6 ||
        !composer_bounds_valid(window, x, y, width, height)) return;
    AccessibleNode *row = new_component(ATK_ROLE_LIST_ITEM, title);
    char id[80];
    snprintf(id, sizeof(id), "linux.conversation.%s.option.%d",
        conversationConfigurationMenuKind == 1 ? "model"
            : conversationConfigurationMenuKind == 2 ? "effort" : "mode", index);
    row->id = g_strdup(id);
    atk_object_set_accessible_id(ATK_OBJECT(row), row->id);
    if (detail) set_description_if_changed(row, detail);
    row->row = index;
    row->bounds = (AtkRectangle){x, y, width, height};
    row->selected = selected != 0;
    row->enabled = enabled != 0;
    row->highlighted = highlighted != 0;
    add_child(conversationConfigurationMenu, row);
    g_object_unref(row);
    refresh_focus();
}
int tw_accessibility_conversation_configuration_identity(int kind, int row,
    char *identity, int capacity) {
    if (!bridgeReady || kind < 1 || kind > 3 || !identity ||
        capacity < MAX_COMPOSER_ID || !conversationConfigurationIdentity[0] ||
        !conversationConfigurationVisible[kind - 1] ||
        !conversationConfigurationChips[kind - 1]->enabled ||
        !node_mounted(ATK_OBJECT(conversationConfigurationChips[kind - 1]))) return 0;
    if (row >= 0) {
        if (conversationConfigurationMenuKind != kind ||
            !node_mounted(ATK_OBJECT(conversationConfigurationMenu))) return 0;
        int found = 0;
        for (guint i = 0; i < conversationConfigurationMenu->children->len; i++) {
            AccessibleNode *candidate = g_ptr_array_index(conversationConfigurationMenu->children, i);
            if (candidate->row == row && !candidate->retired && candidate->enabled) { found = 1; break; }
        }
        if (!found) return 0;
    }
    strcpy(identity, conversationConfigurationIdentity);
    return 1;
}
int tw_accessibility_conversation_configuration_menu_kind(void) {
    return conversationConfigurationMenuKind;
}
static void clear_conversation_context(void) {
    if (!conversationContextVisible) return;
    remove_child((AccessibleNode *)terminal, conversationContextLabel);
    conversationContextVisible = 0;
    conversationContextIdentity[0] = '\0';
    generation++;
}
void tw_accessibility_conversation_context(TWWindow *window, const char *identity,
                                           const char *title, int x, int y, int width, int height) {
    if (!bridgeReady || window != hostWindow) return;
    if (!identity || !title || !identity[0] ||
        strnlen(identity, MAX_COMPOSER_ID) >= MAX_COMPOSER_ID ||
        strnlen(title, 64) >= 64 ||
        !g_utf8_validate(identity, -1, NULL) || !g_utf8_validate(title, -1, NULL) ||
        !composer_bounds_valid(window, x, y, width, height)) {
        clear_conversation_context();
        return;
    }
    if (!conversationContextVisible || strcmp(conversationContextIdentity, identity) != 0) {
        clear_conversation_context();
        g_strlcpy(conversationContextIdentity, identity, sizeof(conversationContextIdentity));
        add_child((AccessibleNode *)terminal, conversationContextLabel);
        conversationContextVisible = 1;
        generation++;
    }
    set_name_if_changed(conversationContextLabel, title);
    conversationContextLabel->bounds = (AtkRectangle){x, y, width, height};
}
void tw_accessibility_show_conversation(TWWindow *window, const char *name) {
    (void)window;
    if (!bridgeReady) return;
    if (name)
        set_name_if_changed((AccessibleNode *)terminal, strnlen(name, 512) < 512 ? name : "[terminal title exceeds 512 bytes]");
    show_content((AccessibleNode *)terminal);
}
void tw_accessibility_show_terminal(TWWindow *window, const char *name) {
    if (!bridgeReady) return;
    clear_attachment_projection();
    clear_conversation_speed();
    clear_conversation_configuration();
    clear_conversation_context();
    tw_accessibility_show_conversation(window, name);
}
void tw_accessibility_terminal_text(TWWindow *window, const char *utf8, int length, int caret,
                                    const TWTextRun *runs, int runCount) {
    (void)window;
    if (!bridgeReady) return;
    set_terminal_text(utf8, length, caret, runs, runCount);
}
#endif
