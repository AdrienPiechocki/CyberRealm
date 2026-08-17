#ifndef EXT_IMAGE_COPY_H
#define EXT_IMAGE_COPY_H

#include "screencast_common.h"

void xdpw_ext_ic_frame_capture(struct xdpw_screencast_instance *cast);
int xdpw_ext_ic_session_init(struct xdpw_screencast_instance *cast);
void xdpw_ext_ic_session_close(struct xdpw_screencast_instance *cast);

// Curseur METADATA : session ext_image_copy_capture_cursor_session + capture
// de l'image du curseur dans un buffer shm dédié.
int xdpw_ext_ic_cursor_session_init(struct xdpw_screencast_instance *cast);
void xdpw_ext_ic_cursor_frame_capture(struct xdpw_screencast_instance *cast);
void xdpw_ext_ic_cursor_session_close(struct xdpw_screencast_instance *cast);

#endif
