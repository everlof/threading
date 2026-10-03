// Compile with Window.c + Accessibility.c and pkg-config --cflags --libs
// sdl2 atk-bridge-2.0 atk gobject-2.0; run under Xvfb and dbus-run-session.
#include "LinuxWindowBridge.h"
#include <SDL2/SDL.h>
#include <atk/atk.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void settle(void) {
    const Uint64 until = SDL_GetTicks64() + 80;
    do {
        SDL_PumpEvents();
        SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);
        SDL_Delay(10);
    } while (SDL_GetTicks64() < until);
}

static TWEvent next(TWWindow *window, int kind, int action, int x, int y) {
    TWEvent result;
    assert(tw_next_timeout(window, &result, 2000) == 1);
    if (result.kind != kind || result.action != action || result.x != x || result.y != y) {
        fprintf(stderr, "expected kind=%d action=%d at %d,%d; got kind=%d action=%d at %d,%d\n",
                kind, action, x, y, result.kind, result.action, result.x, result.y);
        assert(0);
    }
    return result;
}

static void motion(int x, int y, Uint32 state) {
    SDL_Event event = {.type = SDL_MOUSEMOTION};
    event.motion.x = x;
    event.motion.y = y;
    event.motion.state = state;
    assert(SDL_PushEvent(&event) == 1);
}

static void button(Uint32 type, Uint8 which, int x, int y) {
    SDL_Event event = {.type = type};
    event.button.button = which;
    event.button.x = x;
    event.button.y = y;
    assert(SDL_PushEvent(&event) == 1);
}

int main(int argc, char **argv) {
    const int noBus = argc == 2 && strcmp(argv[1], "--no-bus") == 0;
    if (noBus) assert(getenv("DBUS_SESSION_BUS_ADDRESS") == NULL);
    TWWindow *window = tw_open("Navigator pointer contract", 800, 480);
    assert(window);
    if (noBus) {
        tw_project_mode(window);
        settle();
        SDL_Event shortcut = {.type = SDL_KEYDOWN};
        shortcut.key.keysym.sym = SDLK_F10;
        shortcut.key.keysym.scancode = SDL_SCANCODE_F10;
        shortcut.key.keysym.mod = KMOD_SHIFT;
        assert(SDL_PushEvent(&shortcut) == 1);
        next(window, 29, 1, 0, 0);
        shortcut.type = SDL_KEYUP;
        assert(SDL_PushEvent(&shortcut) == 1);
        TWEvent ignored;
        assert(tw_next_timeout(window, &ignored, 30) == 0);
        shortcut.type = SDL_KEYDOWN;
        shortcut.key.keysym.sym = SDLK_APPLICATION;
        shortcut.key.keysym.scancode = SDL_SCANCODE_APPLICATION;
        shortcut.key.keysym.mod = KMOD_NONE;
        assert(SDL_PushEvent(&shortcut) == 1);
        next(window, 29, 1, 0, 0);
        shortcut.type = SDL_KEYUP;
        assert(SDL_PushEvent(&shortcut) == 1);
        assert(tw_next_timeout(window, &ignored, 30) == 0);
        shortcut.type = SDL_KEYDOWN;
        tw_workspace_mode(window, 320, 1);
        settle();
        shortcut.key.keysym.sym = SDLK_F10;
        shortcut.key.keysym.scancode = SDL_SCANCODE_F10;
        shortcut.key.keysym.mod = KMOD_SHIFT;
        assert(SDL_PushEvent(&shortcut) == 1);
        next(window, 29, 1, 0, 0);
        shortcut.type = SDL_KEYUP;
        assert(SDL_PushEvent(&shortcut) == 1);
        assert(tw_next_timeout(window, &ignored, 30) == 0);
        shortcut.type = SDL_KEYDOWN;
        tw_workspace_focus(window, 0);
        settle();
        assert(SDL_PushEvent(&shortcut) == 1);
        TWEvent terminalKey = next(window, 7, 1, 0, 0);
        assert(terminalKey.key == TW_KEY_F10);
        tw_close(window);
        puts("PASS no-bus keyboard Actions shortcut and terminal key isolation");
        return 0;
    }
    tw_workspace_mode(window, 320, 1);
    tw_actions_button(window, "Actions", 1, 208, 8, 100, 36);
    settle();

    // The default path remains the existing C-owned Actions control.
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 250, 20);
    next(window, 26, 2, 0, 0);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 250, 20);
    next(window, 25, 1, 0, 0);
    settle();

    tw_navigator_pointer_route(window, 1);
    motion(42, 110, 0);
    TWEvent event = next(window, 27, 0, 42, 110);
    assert(event.key == 0);
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 42, 110);
    next(window, 27, 1, 42, 110);
    motion(430, 120, SDL_BUTTON_LMASK);
    next(window, 27, 2, 430, 120);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 430, 120);
    next(window, 27, 3, 430, 120);

    motion(45, 113, 0);
    next(window, 27, 0, 45, 113);
    motion(430, 113, 0);
    next(window, 27, 4, 430, 113);
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_RIGHT, 55, 125);
    event = next(window, 27, 5, 55, 125);
    assert(event.key == 2);

    // Actions pointer gestures now reach the mounted control; the C bridge still handles
    // keyboard activation and the published accessibility action.
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 250, 20);
    next(window, 27, 1, 250, 20);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 250, 20);
    next(window, 27, 3, 250, 20);
    SDL_Event key = {.type = SDL_KEYDOWN};
    key.key.keysym.sym = SDLK_SPACE;
    key.key.keysym.scancode = SDL_SCANCODE_SPACE;
    key.key.keysym.mod = KMOD_CTRL | KMOD_SHIFT;
    assert(SDL_PushEvent(&key) == 1);
    event = next(window, 25, 1, 0, 0);
    AtkObject *headerRoot = atk_get_root();
    AtkObject *headerFrame = atk_object_ref_accessible_child(headerRoot, 0);
    AtkObject *headerActions = atk_object_ref_accessible_child(headerFrame, 2);
    assert(atk_object_get_role(headerActions) == ATK_ROLE_PUSH_BUTTON);
    assert(atk_action_do_action(ATK_ACTION(headerActions), 0));
    next(window, 25, 1, 0, 0);
    g_object_unref(headerActions);
    g_object_unref(headerFrame);
    settle();

    // The terminal keeps a press made there, even after crossing into the navigator.
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 430, 145);
    next(window, 15, 1, 110, 145);
    motion(40, 150, SDL_BUTTON_LMASK);
    next(window, 17, 0, 0, 150);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 40, 150);
    next(window, 15, 3, 0, 150);

    // Focus loss cancels a navigator gesture and swallows its late release.
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 55, 160);
    next(window, 27, 1, 55, 160);
    SDL_Event focus = {.type = SDL_WINDOWEVENT};
    focus.window.event = SDL_WINDOWEVENT_FOCUS_LOST;
    assert(SDL_PushEvent(&focus) == 1);
    next(window, 27, 4, 0, 0);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 430, 160);
    assert(tw_next_timeout(window, &event, 30) == 0);
    settle();

    // Some compositors never send that late release. A later terminal press must clear the
    // suppression so its own release cannot be swallowed as the stale navigator release.
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 55, 165);
    next(window, 27, 1, 55, 165);
    assert(SDL_PushEvent(&focus) == 1);
    next(window, 27, 4, 0, 0);
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 440, 170);
    next(window, 15, 1, 120, 170);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 440, 170);
    next(window, 15, 3, 120, 170);
    settle();

    // Focus changes without a pending gesture still reach the Swift host, so selection
    // chrome can change between active and inactive even with no pointer movement.
    focus.window.event = SDL_WINDOWEVENT_FOCUS_GAINED;
    assert(SDL_PushEvent(&focus) == 1);
    next(window, 45, 1, 0, 0);
    focus.window.event = SDL_WINDOWEVENT_FOCUS_LOST;
    assert(SDL_PushEvent(&focus) == 1);
    next(window, 45, 0, 0, 0);
    settle();

    // A standalone navigator accepts its full width; standalone terminal mode does not.
    tw_workspace_mode(window, 0, 0);
    tw_project_mode(window);
    settle();
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 500, 200);
    next(window, 27, 1, 500, 200);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 500, 200);
    next(window, 27, 3, 500, 200);
    tw_terminal_mode(window);
    settle();
    button(SDL_MOUSEBUTTONDOWN, SDL_BUTTON_LEFT, 500, 200);
    next(window, 15, 1, 500, 200);
    button(SDL_MOUSEBUTTONUP, SDL_BUTTON_LEFT, 500, 200);
    next(window, 15, 3, 500, 200);

    // Only a mounted project row has the two independently actionable children. Their slot
    // and exact ID survive the SDL queue; replacement retires both and invalidates events.
    tw_project_mode(window);
    tw_accessibility_begin_list(window, "Projects", 0, 2, 1, 0, 52, 320, 150);
    assert(tw_accessibility_add_project_row(window, "project-one", "Project One", 1,
                                            0, 60, 320, 44, 224, 62, 40, 40,
                                            268, 62, 40, 40, 1) == 0);
    assert(tw_accessibility_add_project_row(window, "project-two", "Project Two", 0,
                                            0, 104, 320, 44, 224, 106, 40, 40,
                                            268, 106, 40, 40, 1) == 0);
    tw_accessibility_end_list(window);
    AtkObject *root = atk_get_root();
    assert(root);
    AtkObject *frame = atk_object_ref_accessible_child(root, 0);
    AtkObject *list = atk_object_ref_accessible_child(frame, 0);
    AtkObject *row = atk_object_ref_accessible_child(list, 0);
    AtkObject *projectCreate = atk_object_ref_accessible_child(row, 0);
    AtkObject *projectAction = atk_object_ref_accessible_child(row, 1);
    AtkObject *secondRow = atk_object_ref_accessible_child(list, 1);
    AtkObject *secondAction = atk_object_ref_accessible_child(secondRow, 1);
    assert(atk_object_get_n_accessible_children(row) == 2);
    assert(atk_object_get_role(projectCreate) == ATK_ROLE_PUSH_BUTTON);
    assert(strcmp(atk_object_get_name(projectCreate), "New chat or terminal") == 0);
    assert(strcmp(atk_object_get_accessible_id(projectCreate),
                  "sidebar.project.create.project-one") == 0);
    assert(atk_object_get_role(projectAction) == ATK_ROLE_PUSH_BUTTON);
    assert(strcmp(atk_object_get_name(projectAction), "Project actions") == 0);
    assert(strcmp(atk_object_get_accessible_id(projectAction),
                  "sidebar.project.actions.project-one") == 0);
    assert(strcmp(atk_object_get_accessible_id(secondAction),
                  "sidebar.project.actions.project-two") == 0);
    assert(atk_object_get_n_accessible_children(list) == 2);
    assert(atk_action_get_n_actions(ATK_ACTION(row)) == 2);
    int x, y, width, height;
    atk_component_get_extents(ATK_COMPONENT(projectAction), &x, &y, &width, &height, ATK_XY_PARENT);
    assert(x == 268 && y == 2 && width == 40 && height == 40);
    atk_component_get_extents(ATK_COMPONENT(projectCreate), &x, &y, &width, &height, ATK_XY_PARENT);
    assert(x == 224 && y == 2 && width == 40 && height == 40);
    AtkObject *hit = atk_component_ref_accessible_at_point(ATK_COMPONENT(row), 270, 10, ATK_XY_PARENT);
    assert(hit == projectAction);
    g_object_unref(hit);
    hit = atk_component_ref_accessible_at_point(ATK_COMPONENT(row), 226, 10, ATK_XY_PARENT);
    assert(hit == projectCreate);
    g_object_unref(hit);
    assert(atk_action_do_action(ATK_ACTION(projectCreate), 0));
    event = next(window, 33, 1, 0, 0);
    assert(event.key == 0 && strcmp(event.text, "project-one") == 0);
    assert(atk_action_do_action(ATK_ACTION(projectAction), 0));
    event = next(window, 28, 1, 0, 0);
    assert(event.key == 0 && strcmp(event.text, "project-one") == 0);
    assert(atk_action_do_action(ATK_ACTION(secondAction), 0));
    event = next(window, 28, 1, 0, 0);
    assert(event.key == 1 && strcmp(event.text, "project-two") == 0);

    tw_navigator_pointer_route(window, 0);
    SDL_Event shortcut = {.type = SDL_KEYDOWN};
    shortcut.key.keysym.sym = SDLK_F10;
    shortcut.key.keysym.scancode = SDL_SCANCODE_F10;
    shortcut.key.keysym.mod = KMOD_SHIFT;
    assert(SDL_PushEvent(&shortcut) == 1);
    event = next(window, 29, 1, 0, 0);
    assert(event.key == 0 && event.text[0] == 0);
    shortcut.key.keysym.sym = SDLK_APPLICATION;
    shortcut.key.keysym.scancode = SDL_SCANCODE_APPLICATION;
    shortcut.key.keysym.mod = KMOD_NONE;
    assert(SDL_PushEvent(&shortcut) == 1);
    event = next(window, 29, 1, 0, 0);
    assert(event.key == 0 && event.text[0] == 0);

    assert(atk_action_do_action(ATK_ACTION(projectAction), 0));
    assert(atk_action_do_action(ATK_ACTION(projectCreate), 0));
    tw_accessibility_begin_list(window, "Projects", 0, 1, 1, 0, 52, 320, 100);
    assert(tw_accessibility_add_project_row(window, "project-two", "Project Two", 1,
                                            0, 60, 320, 44, 224, 62, 40, 40,
                                            268, 62, 40, 40, 1) == 0);
    tw_accessibility_end_list(window);
    assert(tw_next_timeout(window, &event, 30) == 0);
    assert(!atk_action_do_action(ATK_ACTION(projectAction), 0));
    assert(!atk_action_do_action(ATK_ACTION(projectCreate), 0));
    AtkStateSet *oldStates = atk_object_ref_state_set(projectAction);
    assert(atk_state_set_contains_state(oldStates, ATK_STATE_DEFUNCT));
    g_object_unref(oldStates);
    oldStates = atk_object_ref_state_set(projectCreate);
    assert(atk_state_set_contains_state(oldStates, ATK_STATE_DEFUNCT));
    g_object_unref(oldStates);
    g_object_unref(projectCreate);
    g_object_unref(projectAction);
    g_object_unref(row);
    g_object_unref(secondAction);
    g_object_unref(secondRow);
    g_object_unref(list);
    g_object_unref(frame);

    tw_close(window);
    puts("PASS navigator pointer ownership, C fallback, terminal isolation and project AT-SPI action");
    return 0;
}
