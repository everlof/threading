#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

// Holds image/URI requests long enough for the user to edit before text fallback arrives.
int main(void) {
    Display *display = XOpenDisplay(NULL);
    if (!display) return 2;
    Window owner = XCreateSimpleWindow(display, DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);
    Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
    Atom targets = XInternAtom(display, "TARGETS", False);
    Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
    Atom text = XInternAtom(display, "TEXT", False);
    XSetSelectionOwner(display, clipboard, owner, CurrentTime);
    XFlush(display);
    if (XGetSelectionOwner(display, clipboard) != owner) return 3;
    puts("READY");
    fflush(stdout);

    for (;;) {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type != SelectionRequest) continue;
        XSelectionRequestEvent *request = &event.xselectionrequest;
        XSelectionEvent reply = {0};
        reply.type = SelectionNotify;
        reply.display = display;
        reply.requestor = request->requestor;
        reply.selection = request->selection;
        reply.target = request->target;
        reply.time = request->time;
        reply.property = None;
        Atom property = request->property == None ? request->target : request->property;
        if (request->target == targets) {
            Atom offered[] = {targets, utf8, text, XA_STRING};
            XChangeProperty(display, request->requestor, property, XA_ATOM, 32,
                            PropModeReplace, (unsigned char *)offered, 4);
            reply.property = property;
        } else if (request->target == utf8 || request->target == text
                   || request->target == XA_STRING) {
            const char *value = "paste ";
            XChangeProperty(display, request->requestor, property, request->target, 8,
                            PropModeReplace, (const unsigned char *)value, (int)strlen(value));
            reply.property = property;
        } else {
            struct timespec delay = {.tv_sec = 0, .tv_nsec = 300000000};
            nanosleep(&delay, NULL);
        }
        XSendEvent(display, request->requestor, False, 0, (XEvent *)&reply);
        XFlush(display);
    }
}
