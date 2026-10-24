# Breath of the Wild, for dm/ios/tools/auto_run.sh (a DM_CTL file run from the host's start): Continue from the title, the newest save (a Great Plateau save next to
# the big tree west of the Temple of Time; auto_run.sh's DM_AUTO_SAVE pushes the same save every run), walk into the grass right of the tree towards the pines,
# then pan the camera slowly to the right for 90 s (the steady part, between the marks "steady" and "end"). Built on the Mac with screenshots (DM_KEYS-free, waits by draws:
# the title draws about 100 a frame, the save list 260, the loading screen under 40, the plateau 2,500-3,900)
waitdraws 90 20
wait 2
# title: Fortsetzen (Continue) is selected; the save list; Anfangen (Start) in the confirmation
A
wait 2
A
wait 2
A
waitdraws 1500 30 180
mark loaded
wait 3
ls 1 0 1.5
wait 1.6
ls 0.3 1 2.5
wait 3
shot route_spot.png
wait 2
mark steady
rs 0.2 0 90
wait 90
mark end
