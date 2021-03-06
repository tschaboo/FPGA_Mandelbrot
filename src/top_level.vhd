-----------------------------------------------------------------------------
-- Project: mandelbrot_ng - my next-gen FPGA Mandelbrot Fractal Viewer
--
-- File : top_level.vhd
--
-- Author : Mike Field <hamster@snap.net.nz>
--
-- Date    : 9th May 2015
--
-- This is the top level of my fractal viewer. The big difference from 
-- my other attempts is that it doesn't have a freame buffer - all
-- pixels are completely calculated every time they are shown.
--
-- This allows for very smooth scrolling and zooming, with no 
-- restrictions on the speed of scrolling. However the 'depth' is 
-- limited by the resources available on the FPGA and the pixel 
-- clock rate.
--
-- The performance can be tuned to match the Fmax of the FPGA size,
-- FPGA speed and the screen resolution.
--
-- Config rules:
-- 
-- constant clocks_per_pixel : integer := 9;
--     This is the number of clocks per display pixel
--     It can be anything from 1 to 12. If anything above 12  
--     is used the pipeline in "stage" will eject a pxel too
--     early.
--
-- constant stages : integer := 12;
--     Number of processing stages in the processing pipeline
--     Alter this to change the number of DSP blocks used
--
-- With these values it will allow you to explore at depths of  
-- of 9*12 = 108 iterations. On a larger FPGA you can increase
-- the values.
--
-- Also in stage.vhd, you have the option to implement some of the 
-- multiplications using LUTs rather than DSP blocks. Adjusting
-- this can allow you to include extra stages.
-- 
-- It is currently configured to use 7 DSP blocks per stage, out
-- of a maximum of 10 (the other three are implemented in LUTs). 
--
--
  
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

Library UNISIM;
use UNISIM.vcomponents.all;

entity top_level is
    Port ( 
        clk100      : in STD_LOGIC;
        
        btnU      : in STD_LOGIC;
        btnD      : in STD_LOGIC;
        btnL      : in STD_LOGIC;
        btnR      : in STD_LOGIC;
        btnC      : in STD_LOGIC;
        
        VGA_R   : out std_logic_vector(3 downto 0);
        VGA_G   : out std_logic_vector(3 downto 0);
        VGA_B   : out std_logic_vector(3 downto 0);
        VGA_HS  : out std_logic;
        VGA_VS  : out std_logic
);
end top_level;

architecture Behavioral of top_level is
    constant clocks_per_pixel : integer :=  3;
    
    constant stages    : integer := 30;
    constant lut_mults : integer := 2;
    
    signal clk_calc      : std_logic;
    signal clk_pixel_x1  : std_logic;

    signal blank : std_logic := '0';
    signal hsync : std_logic := '0';
    signal vsync : std_logic := '0';
    signal field         : std_logic;
    signal interlaced    : std_logic;

    component mmcm_wrapper is
        generic ( div_to_25MHz  : integer );
        Port (
            clk_in        : in  std_logic;
            locked        : out std_logic;
            clk_calc      : out std_logic;
            clk_pixel_x1  : out std_logic
         );
    end component;

    component vga_gen_720p is
        port (
           clk        : in  std_logic;
            
           blank      : out std_logic;
           hsync      : out std_logic;
           vsync      : out std_logic;
           field      : out std_logic;
           interlaced : out std_logic
           );
    end component;    

    component vga_gen_1080i is
        port (
           clk        : in  std_logic;
            
           blank      : out std_logic;
           hsync      : out std_logic;
           vsync      : out std_logic;
           field      : out std_logic;
           interlaced : out std_logic
        );
    end component;    

    component user_interface is
        port (
            clk       : in STD_LOGIC;
            btnU      : in STD_LOGIC;
            btnD      : in STD_LOGIC;
            btnL      : in STD_LOGIC;
            btnR      : in STD_LOGIC;
            btnC      : in STD_LOGIC;

            vsync     : in STD_LOGIC;
            x         : out std_logic_vector(34 downto 0);
            y         : out std_logic_vector(34 downto 0);
            scale     : out std_logic_vector(34 downto 0)
           );
    end component;
                                                --- these are in 4.31 fixed-point signed binary
    signal x      : std_logic_vector(34 downto 0) := (others => '0');
    signal y      : std_logic_vector(34 downto 0) := (others => '0');
    signal scale  : std_logic_vector(34 downto 0) := (others => '0');
    
    signal ca_new   : std_logic_vector(34 downto 0) := (others => '0');
    signal cb_new   : std_logic_vector(34 downto 0) := (others => '0');
    signal sync_new : std_logic_vector( 2 downto 0) := (others => '0');


    type a_fixed_point is array (0 to stages) of std_logic_vector(34 downto 0);
    type a_count       is array (0 to stages) of std_logic_vector(7 downto 0);
    type a_sync        is array (0 to stages) of std_logic_vector(2 downto 0);

    signal ca         : a_fixed_point := (others => (others => '0'));
    signal cb         : a_fixed_point := (others => (others => '0'));
    signal a          : a_fixed_point := (others => (others => '0'));
    signal b          : a_fixed_point := (others => (others => '0'));
    signal iterations : a_count       := (0 => "00000001", others => (others => '0'));
    signal sync       : a_sync        := (others => (others => '0'));
    signal overflow   : unsigned(stages downto 0) := (others => '0');

    component generate_constants is
        port (
            clk       : in std_logic;

            blank_in   : in std_logic;
            hsync_in   : in std_logic;
            vsync_in   : in std_logic;
            field      : in std_logic;
            interlaced : in std_logic;

            x         : in  std_logic_vector;
            y         : in  std_logic_vector;
            x_step    : in  std_logic_vector;
            y_step    : in  std_logic_vector;
            
            blank_out : out std_logic;
            hsync_out : out std_logic;
            vsync_out : out std_logic;
            
            ca        : out std_logic_vector;
            cb        : out std_logic_vector

        );
    end component;
    
    component stage is 
    generic (
        phase_len     : integer;
        use_lut_mults : integer 
    );
    port (
        clk    : std_logic;
        -- Inputs
        ca_in        : in std_logic_vector; -- The real constant
        cb_in        : in std_logic_vector; -- The imaginary constant
        a_in         : in std_logic_vector; -- the current real value
        b_in         : in std_logic_vector; -- the current imaginary value
        i_in         : in std_logic_vector; -- the current increment count
        overflow_in  : in std_logic;        -- has an overflow occured?
        sync_in      : in std_logic_vector; -- any control/video signals along for the ride

        ca_out       : out std_logic_vector;
        cb_out       : out std_logic_vector;
        a_out        : out std_logic_vector;
        b_out        : out std_logic_vector;
        i_out        : out std_logic_vector;
        overflow_out : out std_logic;
        sync_out     : out std_logic_vector
    );
    end component;

    component vga_output is
        Port ( clk : in STD_LOGIC;
               hsync_in : in STD_LOGIC;
               vsync_in : in STD_LOGIC;
               blank_in : in STD_LOGIC;
               iterations_in : in STD_LOGIC_VECTOR(7 downto 0);
               vga_hsync : out std_logic;
               vga_vsync : out std_logic;
               vga_red   : out std_logic_vector(7 downto 0);
               vga_green : out std_logic_vector(7 downto 0);
               vga_blue  : out std_logic_vector(7 downto 0);
               vga_blank : out std_logic);
    end component;

    signal vga_hsync     : std_logic;
    signal vga_vsync     : std_logic;
    signal vga_red       : std_logic_vector(7 downto 0);
    signal vga_green     : std_logic_vector(7 downto 0);
    signal vga_blue      : std_logic_vector(7 downto 0);
    signal vga_blank     : std_logic;

    signal reset         : std_logic;

    signal locked        : std_logic;
    signal clkfb         : std_logic;

    signal mmcm_clk_in   : std_logic;
begin
    reset <= not locked;

    mmcm_clk_in <= clk100;

i_clk_gen1 : mmcm_wrapper generic map (
       div_to_25MHz => 4  -- For a 100Mhz Clk
    ) port map (
      clk_in       => mmcm_clk_in,
      locked       => locked,
      clk_calc     => clk_calc,
      clk_pixel_x1 => clk_pixel_x1
);

i_ui: user_interface  port map (
           clk   => clk_pixel_x1,
           btnU  => btnU,
           btnD  => btnD,
           btnL  => btnL,
           btnR  => btnR,
           btnC  => btnC,
           
           vsync => vsync,
           x     => x,
           y     => y,
           scale => scale
          );

i_vga_gen_720p: vga_gen_720p port map (
        clk        => clk_pixel_x1,
        blank      => blank, 
        hsync      => hsync,
        vsync      => vsync,
        field      => field,
        interlaced => interlaced
    );

i_generate_constants: generate_constants port map (
        clk       => clk_pixel_x1,

        blank_in   => blank,
        hsync_in   => hsync,
        vsync_in   => vsync,
        field      => field,
        interlaced => interlaced,
        
        x         => x,
        y         => y,
        x_step    => scale, 
        y_step    => scale,
        
        blank_out => sync(0)(0),
        hsync_out => sync(0)(1),
        vsync_out => sync(0)(2),
        
        ca        => ca(0),
        cb        => cb(0)
    );
    a(0)          <= (others =>'0'); 
    b(0)          <= (others =>'0'); 
    -- set starting colour
    overflow(0)   <= '0';  

g_stages: for i in 1 to stages generate
i_stage_1: stage generic map (
            phase_len     => clocks_per_pixel,
            use_lut_mults => lut_mults
        ) port map (
            clk        => clk_calc,
            -- Inputs
            ca_in        => ca(i-1),
            cb_in        => cb(i-1),
            a_in         => a(i-1), 
            b_in         => b(i-1), 
            i_in         => iterations(i-1), 
            overflow_in  => overflow(i-1),
            sync_in      => sync(i-1),
    
            ca_out       => ca(i),
            cb_out       => cb(i),
            a_out        => a(i),
            b_out        => b(i),
            i_out        => iterations(i),
            overflow_out => overflow(i),
            sync_out     => sync(i)
        );
end generate;

    
i_vga_output: vga_output Port map ( 
            clk => clk_pixel_x1,
            hsync_in => sync(stages)(1),
            vsync_in => sync(stages)(2),
            blank_in => sync(stages)(0),
            iterations_in => iterations(stages),
            vga_hsync => vga_hsync, 
            vga_vsync => vga_vsync,
            vga_red   => vga_red,
            vga_green => vga_green,
            vga_blue  => vga_blue,
            vga_blank => vga_blank
        );
    
    VGA_R <= vga_red(6 downto 3);
    VGA_G <= vga_green(6 downto 3);
    VGA_B <= vga_blue(6 downto 3);
    VGA_HS <= vga_hsync;
    VGA_VS <= vga_vsync;
            

end Behavioral;
