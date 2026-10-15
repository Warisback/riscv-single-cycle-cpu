# grab.tcl: GTKWave script (gtkwave -S) that saves a picture of the GTKWave window.
# tools/gtkwave_shot.sh runs it; the settings come from environment variables:
#   GRAB_FROM, GRAB_TO   time range to show, in VCD time units (picoseconds here)
#   GRAB_PNG             PNG file to write, relative to the current folder
# It zooms the wave window to the range, writes the PNG with GTKWave's own
# File > Grab To File, then quits.

set from $::env(GRAB_FROM)
set to   $::env(GRAB_TO)
set png  $::env(GRAB_PNG)

# Give GTKWave time to draw the window before and after each step.
proc settle {} {
  for {set i 0} {$i < 10} {incr i} {
    gtkwave::nop
    after 100
  }
}

settle
# The window can show a little more than the range asked for, so shorten the
# range until its right edge is at most GRAB_TO.
set end $to
for {set k 0} {$k < 5} {incr k} {
  gtkwave::setZoomRangeTimes $from $end
  gtkwave::setWindowStartTime $from
  settle
  set shown_from [gtkwave::getWindowStartTime]
  set shown_to [gtkwave::getWindowEndTime]
  puts "grab: asked for $from..$end, the window shows $shown_from..$shown_to"
  if {$shown_to <= $to} {
    break
  }
  set end [expr {$end - ($shown_to - $to)}]
}
settle
gtkwave::/File/Grab_To_File $png
settle
gtkwave::/File/Quit
