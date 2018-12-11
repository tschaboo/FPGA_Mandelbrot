Mandelbrot fractal view for Nexys Video and Genesys2 FPGA dev boards.

More information to come...

------------------------------------

2018-12-11 by tschaboo
Ported to Nexys A7-100 in a quick and dirty way: stripped out anything not
applicable to this board (HDMI, rotary encoder, ADC, ...). Also some of the
configurabilty is gone.

If you want to port to a different board better get the upstream source.

In the current configuration (30 stages, 3 clocks_per_pixel) all 240 DSPs
are in use. Output is 720p60.
