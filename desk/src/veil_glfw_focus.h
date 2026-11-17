#ifndef VEIL_GLFW_FOCUS_H
#define VEIL_GLFW_FOCUS_H

/* Attached input queues can make GetActiveWindow return a window from another
 * process. GLFW stores a raw pointer in its HWND property, so check ownership
 * before GLFW can use the other process's pointer. */
static HWND veilGlfwActiveWindow(void)
{
    HWND window = GetActiveWindow();
    DWORD owner = 0;
    if (window)
        GetWindowThreadProcessId(window, &owner);
    return owner == GetCurrentProcessId() ? window : NULL;
}

#define GetActiveWindow veilGlfwActiveWindow

#endif
