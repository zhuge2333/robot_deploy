#!/usr/bin/env python3
"""Patch ros_camera_server selectCaps to accept discrete framerate GstValueLists.

UVC cameras commonly expose caps like `framerate={120/1, 60/1, 30/1, ...}` (a
GstValueList). Upstream selectCaps() only handles a single fraction or a
fraction range, so every list entry falls through and pipeline build fails with
"No caps matching WxH @ N/1 ...". This patch adds list handling: match when the
desired framerate equals any list entry.
"""
import sys

PATHS = [
    "/ws/src/ros_camera_server/ros_camera_server/src/inputs/v4l2_input.cpp",
]

ANCHOR = "      } else if ( GST_VALUE_HOLDS_FRACTION_RANGE( fr_value ) ) {"

INSERT = """      } else if ( GST_VALUE_HOLDS_LIST( fr_value ) ) {
        // UVC cameras often expose discrete framerates as a GstValueList; match when
        // the desired framerate is one of the list entries.
        bool matched_framerate = false;
        for ( guint list_index = 0; list_index < gst_value_list_get_size( fr_value );
              ++list_index ) {
          const GValue *list_item = gst_value_list_get_value( fr_value, list_index );
          if ( GST_VALUE_HOLDS_FRACTION( list_item ) ) {
            Framerate list_framerate( gst_value_get_fraction_numerator( list_item ),
                                      gst_value_get_fraction_denominator( list_item ) );
            if ( !( list_framerate != framerate ) ) {
              matched_framerate = true;
              break;
            }
          }
        }
        if ( !matched_framerate )
          continue;
      } else if ( GST_VALUE_HOLDS_FRACTION_RANGE( fr_value ) ) {"""

for path in PATHS:
    with open(path) as f:
        src = f.read()
    if "GST_VALUE_HOLDS_LIST( fr_value )" in src:
        print(f"{path}: already patched")
        continue
    if ANCHOR not in src:
        print(f"{path}: ERROR anchor not found", file=sys.stderr)
        sys.exit(1)
    with open(path, "w") as f:
        f.write(src.replace(ANCHOR, INSERT, 1))
    print(f"{path}: PATCHED")
