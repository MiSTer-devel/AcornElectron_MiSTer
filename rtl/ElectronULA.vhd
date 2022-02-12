--------------------------------------------------------------------------------
-- Copyright (c) 2015 David Banks
--------------------------------------------------------------------------------
--   ____  ____
--  /   /\/   /
-- /___/  \  /
-- \   \   \/
--  \   \
--  /   /         Filename  : ElectronFpga_core.vhd
-- /___/   /\     Timestamp : 28/07/2015
-- \   \  /  \
--  \___\/\___\
--
--Design Name: ElectronFpga_core


-- TODO:
-- Implement Cassette Out

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity ElectronULA is
    generic (
        IncludeMMC       : boolean := true;
        Include32KRAM    : boolean := true;
        IncludeVGA       : boolean := true;
        IncludeJafaMode7 : boolean := false
    );
    port (
        clk_16M00 : in  std_logic;
        clk_24M00 : in  std_logic;
        clk_32M00 : in  std_logic;
        clk_33M33 : in  std_logic;
        clk_40M00 : in  std_logic;

        -- CPU Interface
        addr      : in  std_logic_vector(15 downto 0);
        data_in   : in  std_logic_vector(7 downto 0);
        data_out  : out std_logic_vector(7 downto 0);
        data_en   : out std_logic;
        R_W_n     : in  std_logic;
        RST_n     : in  std_logic;
        IRQ_n     : out std_logic;
        NMI_n     : in  std_logic;

        -- Rom Enable
        ROM_n     : out std_logic;

        -- Video
		  cepix		: out std_logic;
        red       : out std_logic_vector(3 downto 0);
        green     : out std_logic_vector(3 downto 0);
        blue      : out std_logic_vector(3 downto 0);
        vsync     : out std_logic;
        hsync     : out std_logic;
		  hblank		: out std_logic;
		  vblank		: out std_logic;

        -- Audio
        sound     : out std_logic;

        -- Keyboard
        kbd       : in  std_logic_vector(3 downto 0);

        -- SD Card
        SDMISO    : in  std_logic;
        SDSS      : out std_logic;
        SDCLK     : out std_logic;
        SDMOSI    : out std_logic;

        -- Casette
        casIn     : in  std_logic;
        casOut    : out std_logic;

        -- MISC
        caps      : out std_logic;
        motor     : out std_logic;

        rom_latch : out std_logic_vector(3 downto 0);

        mode_init : in std_logic_vector(1 downto 0);

        -- Clock Generation
        cpu_clken_out  : out std_logic;
        turbo          : in std_logic_vector(1 downto 0);
        turbo_out      : out std_logic_vector(1 downto 0);

        -- Joystick Inputs
	joystick1_x   : in std_logic_vector(7 downto 0);
	joystick1_y   : in std_logic_vector(7 downto 0);
	joystick1_fire   : in std_logic;
	joystick2_x   : in std_logic_vector(7 downto 0);
	joystick2_y   : in std_logic_vector(7 downto 0);
	joystick2_fire   : in std_logic;
		  
		  
        -- Output to sync overlay
	h_cnt: out std_logic_vector(10  downto 0);
	v_cnt: out std_logic_vector( 9  downto 0)

        );
end;

architecture behavioral of ElectronULA is

  signal hsync_int      : std_logic;
  signal vsync_int      : std_logic;

  signal ram_we         : std_logic;
  signal ram_data       : std_logic_vector(7 downto 0);

  signal master_irq     : std_logic;

  signal power_on_reset : std_logic := '1';
  signal delayed_clear_reset : std_logic := '0';

  signal rtc_counter    : std_logic_vector(18 downto 0);
  signal general_counter: std_logic_vector(15 downto 0);
  signal sound_bit      : std_logic;
  signal isr_data       : std_logic_vector(7 downto 0);

  -- ULA Registers
  signal isr            : std_logic_vector(6 downto 2);
  signal ier            : std_logic_vector(6 downto 2);
  signal screen_base    : std_logic_vector(14 downto 6);
  signal data_shift     : std_logic_vector(7 downto 0);
  signal page_enable    : std_logic;
  signal page           : std_logic_vector(2 downto 0);
  signal counter        : std_logic_vector(7 downto 0);
  signal display_mode   : std_logic_vector(2 downto 0);
  signal comms_mode     : std_logic_vector(1 downto 0);

  type palette_type is array (0 to 7) of std_logic_vector (7 downto 0);
  signal palette        : palette_type;

  signal hsync_start    : std_logic_vector(10 downto 0);
  signal hsync_end      : std_logic_vector(10 downto 0);
  signal h_active       : std_logic_vector(10 downto 0);
  signal h_total        : std_logic_vector(10 downto 0);
  signal h_count        : std_logic_vector(10 downto 0);
  signal h_count1       : std_logic_vector(10 downto 0);

  signal vsync_start    : std_logic_vector(9 downto 0);
  signal vsync_end      : std_logic_vector(9 downto 0);
  signal v_active_gph   : std_logic_vector(9 downto 0);
  signal v_active_txt   : std_logic_vector(9 downto 0);
  signal v_total        : std_logic_vector(9 downto 0);
  signal v_count        : std_logic_vector(9 downto 0);

  signal v_rtc          : std_logic_vector(9 downto 0);
  signal v_display      : std_logic_vector(9 downto 0);

  signal char_row       : std_logic_vector(3 downto 0);
  signal row_offset     : std_logic_vector(14 downto 0);
  signal col_offset     : std_logic_vector(9 downto 0);
  signal screen_addr    : std_logic_vector(14 downto 0);
  signal screen_data    : std_logic_vector(7 downto 0);

  -- Screen Mode Registers

  signal mode           : std_logic_vector(1 downto 0);

  -- the 256 byte page that the mode starts at
  signal mode_base      : std_logic_vector(7 downto 0);

  -- the number of bits per pixel (0 = 1BPP, 1 = 2BPP, 2=4BPP)
  signal mode_bpp       : std_logic_vector(1 downto 0);

   -- a '1' indicates a text mode (modes 3 and 6)
  signal mode_text      : std_logic;

  -- a '1' indicates a 40-col mode (modes 4, 5 and 6)
  signal mode_40        : std_logic;

  -- the number of bytes to increment row_offset when moving from one char row to the next
  signal mode_rowstep   : std_logic_vector(9 downto 0);

  signal display_intr   : std_logic;
  signal display_intr1  : std_logic;
  signal display_intr2  : std_logic;

  signal rtc_intr       : std_logic;
  signal rtc_intr1      : std_logic;
  signal rtc_intr2      : std_logic;

  signal clk_video      : std_logic;

  signal ctrl_caps      : std_logic;

  signal field          : std_logic;

  signal caps_int       : std_logic;
  signal motor_int      : std_logic;

  -- Supports changing the jumpers
  signal mode_init_copy : std_logic_vector(1 downto 0);

  -- Stable copies sampled once per frame
  signal screen_base1   : std_logic_vector(14 downto 6);
  signal mode_base1     : std_logic_vector(7 downto 0);

  -- Tape Interface
  signal cintone        : std_logic;
  signal cindat         : std_logic;
  signal cinbits        : std_logic_vector(3 downto 0);
  signal coutbits       : std_logic_vector(3 downto 0);
  signal casIn1         : std_logic;
  signal casIn2         : std_logic;
  signal casIn3         : std_logic;
  signal ignore_next    : std_logic;

  -- internal RGB signals before final mux
  signal red_int        : std_logic_vector(3 downto 0);
  signal green_int      : std_logic_vector(3 downto 0);
  signal blue_int       : std_logic_vector(3 downto 0);

  signal adc_chan       : std_logic_vector(3 downto 0);
  signal plus_1_stat_reg :std_logic_vector(7 downto 0);
  signal plus_1_adc_data       : std_logic_vector (7 downto 0);
  signal plus_1_adc_n_intr : std_logic;
  -- CRTC signals (only used when Jafa Mode 7 is enabled)
--  signal crtc_enable    :   std_logic;
--  signal crtc_clken     :   std_logic;
--  signal crtc_do        :   std_logic_vector(7 downto 0);
--  signal crtc_vsync     :   std_logic;
--  signal crtc_vsync_n   :   std_logic;
--  signal crtc_hsync     :   std_logic;
--  signal crtc_hsync_n   :   std_logic;
--  signal crtc_de        :   std_logic;
--  signal crtc_cursor    :   std_logic;
--  signal crtc_cursor1   :   std_logic;
--  signal crtc_cursor2   :   std_logic;
  signal crtc_ma        :   std_logic_vector(13 downto 0) := (others => '0');
--  signal crtc_ra        :   std_logic_vector(4 downto 0);
--  signal status_enable  :   std_logic;
--  signal status_do      :   std_logic_vector(7 downto 0);

  -- SAA5050 signals (only used when Jafa Mode 7 is enabled)
--  signal ttxt_clken     :   std_logic;
--  signal ttxt_glr       :   std_logic;
--  signal ttxt_dew       :   std_logic;
--  signal ttxt_crs       :   std_logic;
--  signal ttxt_lose      :   std_logic;
--  signal ttxt_r_int     :   std_logic;
--  signal ttxt_g_int     :   std_logic;
--  signal ttxt_b_int     :   std_logic;
--  signal ttxt_r         :   std_logic;
--  signal ttxt_g         :   std_logic;
--  signal ttxt_b         :   std_logic;
  signal ttxt_r_out     :   std_logic:= '0';
  signal ttxt_g_out     :   std_logic:= '0';
  signal ttxt_b_out     :   std_logic:= '0';
  signal ttxt_hs_out    :   std_logic:= '0';
  signal ttxt_vs_out    :   std_logic:= '0';
--  signal mist_r         :   std_logic_vector(1 downto 0);
--  signal mist_g         :   std_logic_vector(1 downto 0);
--  signal mist_b         :   std_logic_vector(1 downto 0);
--  signal mist_hs        :   std_logic;
--  signal mist_vs        :   std_logic;

  signal mode7_enable   :   std_logic;

  -- internal signals to generate the video clock
  signal clk_16M00_a    :   std_logic;
  signal clk_16M00_b    :   std_logic;
  signal clk_16M00_c    :   std_logic;
  signal clk_33M33_a    :   std_logic;
  signal clk_33M33_b    :   std_logic;
  signal clk_33M33_c    :   std_logic;
  signal clk_40M00_a    :   std_logic;
  signal clk_40M00_b    :   std_logic;
  signal clk_40M00_c    :   std_logic;

  signal ROM_n_int      :   std_logic;

  -- clock enable generation
  signal clken_counter     : std_logic_vector (3 downto 0);

  signal contention     : std_logic;
  signal contention1    : std_logic;
  signal contention2    : std_logic;
  signal rom_access     : std_logic; -- always at 2mhz, no contention
  signal ram_access     : std_logic; -- 1MHz/2Mhz/Stopped

  signal clk_state      : std_logic_vector(2 downto 0);
  signal cpu_clken      : std_logic;
  signal cpu_clken_1    : std_logic;
  signal cpu_clken_2    : std_logic;
  signal cpu_clken_4    : std_logic;
  signal via1_clken     : std_logic;
  signal via1_clken_1   : std_logic;
  signal via1_clken_2   : std_logic;
  signal via1_clken_4   : std_logic;
  signal via2_clken     : std_logic;
  signal via2_clken_1   : std_logic;
  signal via2_clken_2   : std_logic;
  signal via2_clken_4   : std_logic;

  signal mc6522_enable     : std_logic;
  signal mc6522_data       : std_logic_vector(7 downto 0);
  signal mc6522_irq        : std_logic;
  -- Port A is not really used, so signals directly loop back out to in
  signal mc6522_ca2        : std_logic;
  signal mc6522_porta      : std_logic_vector(7 downto 0);
  -- Port B is used for the MMBEEB style SDCard Interface
  signal mc6522_cb1_in     : std_logic;
  signal mc6522_cb1_out    : std_logic;
  signal mc6522_cb1_oe     : std_logic;
  signal mc6522_cb2_in     : std_logic;
  signal mc6522_portb_in   : std_logic_vector(7 downto 0);
  signal mc6522_portb_out  : std_logic_vector(7 downto 0);
  signal mc6522_portb_oe   : std_logic_vector(7 downto 0);
  signal sdclk_int         : std_logic;

  signal ula_irq_n         : std_logic;
  
  
-- Helper function to cast an std_logic value to an integer
function sl2int (x: std_logic) return integer is
begin
    if x = '1' then
        return 1;
    else
        return 0;
    end if;
end;

-- Helper function to cast an std_logic_vector value to an integer
function slv2int (x: std_logic_vector) return integer is
begin
    return to_integer(unsigned(x));
end;

begin

	cepix <= clk_video;

    -- video timing constants
    -- mode 00 - RGB/s @ 50Hz non-interlaced
    -- mode 01 - RGB/s @ 50Hz interlaced
    -- mode 10 - SVGA  @ 50Hz
    -- mode 11 - SVGA  @ 60Hz

	 --clk_video <= clk_16M00;
	 
    -- A simple clock mux causes lots of warnings from the Xilinx tool
    --  clk_video    <= clk_40M00 when mode = "11" else
    --                  clk_33M33 when mode = "10" else
    --                  clk_16M00;
    -- Instead, we regenerate the clock using edge triggered flip flops

    process(clk_16M00)
    begin
        if rising_edge(clk_16M00) then
            clk_16M00_a <= not clk_16M00_a;
        end if;
    end process;

    process(clk_16M00)
    begin
        if falling_edge(clk_16M00) then
            clk_16M00_b <= not clk_16M00_b;
        end if;
    end process;

    clk_16M00_c <= clk_16M00_a xor clk_16M00_b;

    process(clk_33M33)
    begin
        if rising_edge(clk_33M33) then
            clk_33M33_a <= not clk_33M33_a;
        end if;
    end process;

    process(clk_33M33)
    begin
        if falling_edge(clk_33M33) then
            clk_33M33_b <= not clk_33M33_b;
        end if;
    end process;

    clk_33M33_c <= clk_33M33_a xor clk_33M33_b;

    process(clk_40M00)
    begin
        if rising_edge(clk_40M00) then
            clk_40M00_a <= not clk_40M00_a;
        end if;
    end process;

    process(clk_40M00)
    begin
        if falling_edge(clk_40M00) then
            clk_40M00_b <= not clk_40M00_b;
        end if;
    end process;

    clk_40M00_c <= clk_40M00_a xor clk_40M00_b;


    clk_video    <= clk_40M00_c when mode = "11" and IncludeVGA else
                    clk_33M33_c when mode = "10" and IncludeVGA else
                    clk_16M00_c;


    hsync_start  <= std_logic_vector(to_unsigned(759, 11)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(759, 11)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(762, 11));

    hsync_end    <= std_logic_vector(to_unsigned(887, 11)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(887, 11)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(837, 11));

    h_total      <= std_logic_vector(to_unsigned(1055, 11)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(1055, 11)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(1023, 11));

    h_active     <= std_logic_vector(to_unsigned(640, 11));

    vsync_start  <= std_logic_vector(to_unsigned(556, 10)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(556, 10)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(274, 10));

    vsync_end    <= std_logic_vector(to_unsigned(560, 10)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(560, 10)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(277, 10));

    v_total      <= std_logic_vector(to_unsigned(627, 10)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(627, 10)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(311, 10)) when field = '0'                else
                    std_logic_vector(to_unsigned(312, 10));

    v_active_gph <= std_logic_vector(to_unsigned(512, 10)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(512, 10)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(256, 10));

    v_active_txt <= std_logic_vector(to_unsigned(500, 10)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(500, 10)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(250, 10));

    v_display    <= std_logic_vector(to_unsigned(513, 10)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(513, 10)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(256, 10));

    v_rtc        <= std_logic_vector(to_unsigned(201, 10)) when mode = "11" and IncludeVGA else
                    std_logic_vector(to_unsigned(201, 10)) when mode = "10" and IncludeVGA else
                    std_logic_vector(to_unsigned(100, 10));


    -- All of main memory (0x0000-0x7fff) is dual port RAM in the ULA

        ram_32k : entity work.RAM_32K_DualPort port map(
            -- Port A is the 6502 port
            clock_a  => clk_16M00,
            wren_a   => ram_we,
            address_a => addr(14 downto 0),
            data_a  => data_in,
            q_a => ram_data,
            -- Port B is the VGA Port
            clock_b  => clk_video,
            wren_b   => '0',
            address_b => screen_addr,
            data_b  => x"00",
            q_b => screen_data
            );
        ram_we <= '1' when addr(15) = '0' and R_W_n = '0' and cpu_clken = '1' else '0';

    sound <= sound_bit;

    -- The external ROM is enabled:
    -- - When the address is C000-FBFF and FF00-FFFF (i.e. OS Rom)
    -- - When the address is 8000-BFFF and the ROM 10 or 11 is paged in (101x)
    ROM_n_int <= '0' when addr(15 downto 14) = "11" and addr(15 downto 8) /= x"FC" and addr(15 downto 8) /= x"FD" and addr(15 downto 8) /= x"FE" else
                 '0' when addr(15 downto 14) = "10" and page_enable = '1' and page(2 downto 1) = "01" else
                 '1';

    ROM_n <= ROM_n_int;

    -- ULA Reads + RAM Reads + KBD Reads
    data_out <= ram_data                  when addr(15) = '0' else
                "0000" & (kbd xor "1111") when addr(15 downto 14) = "10" and page_enable = '1' and page(2 downto 1) = "00" else
                isr_data                  when addr(15 downto 8) = x"FE" and addr(3 downto 0) = x"0" else
                data_shift                when addr(15 downto 8) = x"FE" and addr(3 downto 0) = x"4" else
--                crtc_do                   when crtc_enable = '1' and IncludeJafaMode7 else
--                status_do                 when status_enable = '1' and IncludeJafaMode7 else
                mc6522_data               when mc6522_enable = '1' and IncludeMMC else
					 plus_1_stat_reg           when addr = x"FC72" else
					 plus_1_adc_data          when addr = x"FC70" else
                x"F1"; -- todo FIXEME

    data_en  <= '1'                       when addr(15) = '0' else
                '1'                       when addr(15 downto 14) = "10" and page_enable = '1' and page(2 downto 1) = "00" else
                '1'                       when addr(15 downto 8) = x"FE" else
--                '1'                       when crtc_enable = '1' and IncludeJafaMode7 else
--                '1'                       when status_enable = '1' and IncludeJafaMode7 else
                '1'                       when mc6522_enable = '1' and IncludeMMC else
					'1' 								when addr = x"FC72" else
					'1'								when addr = x"FC70" else

                '0';

    -- Register FEx0 is the Interrupt Status Register (Read Only)
    -- Bit 7 always reads as 1
    -- Bits 6..2 refect in interrups status regs
    -- Bit 1 is the power up reset bit, cleared by the first read after power up
    -- Bit 0 is the OR of bits 6..2
    master_irq <= (isr(6) and ier(6)) or
                  (isr(5) and ier(5)) or
                  (isr(4) and ier(4)) or
                  (isr(3) and ier(3)) or
                  (isr(2) and ier(2));

    ula_irq_n  <= not master_irq;

    isr_data   <= '1' & isr(6 downto 2) & power_on_reset & master_irq;

    rom_latch  <= page_enable & page;

    process (clk_16M00, RST_n)
    begin

        if rising_edge(clk_16M00) then

            if (RST_n = '0') then

               isr             <= (others => '0');
               ier             <= (others => '0');
               screen_base     <= (others => '0');
               data_shift      <= (others => '0');
               page_enable     <= '0';
               page            <= (others => '0');
               counter         <= (others => '0');
               comms_mode      <= "01";
               motor_int       <= '0';
               caps_int        <= '0';
               rtc_counter     <= (others => '0');
               general_counter <= (others => '0');
               sound_bit       <= '0';
               mode            <= mode_init;
               mode_init_copy  <= mode_init;
               ctrl_caps       <= '0';
               cindat          <= '0';
               cintone         <= '0';
               turbo_out       <= "01";

            else
                -- Detect Jumpers being changed
                if (mode_init_copy /= mode_init) then
                    mode <= mode_init;
                    mode_init_copy <= mode_init;
                end if;
                -- Synchronize the display interrupt signal from the VGA clock domain
                display_intr1 <= display_intr;
                display_intr2 <= display_intr1;
                -- Generate the display end interrupt on the rising edge (line 256 of the screen)
                if (display_intr2 = '0' and display_intr1 = '1') then
                    isr(2) <= '1';
                end if;
                -- Synchronize the rtc interrupt signal from the VGA clock domain
                rtc_intr1 <= rtc_intr;
                rtc_intr2 <= rtc_intr1;
                if mode = "11" and IncludeVGA then
                    -- For 60Hz frame rates we must synthesise a the 50Hz real time clock interrupt
                    -- In theory the counter limit should be 319999, but there are additional
                    -- rtc ticks if not rtc interrupt is received between two display interrupts
                    -- hence the correction factor of 6/5. This comes from the probability
                    -- of the there not being a 50Hz rtc interrupts between any two successive
                    -- 60Hz display interrupts.
                    if (rtc_counter = 383999) then
                        rtc_counter <= (others => '0');
                        isr(3) <= '1';
                    else
                        rtc_counter <= rtc_counter + 1;
                    end if;
                else
                    -- Generate the rtc interrupt on the rising edge (line 100 of the screen)
                    if (rtc_intr2 = '0' and rtc_intr1 = '1') then
                        isr(3) <= '1';
                    end if;
                end if;
                if (comms_mode = "00") then
                    -- Cassette In Mode
                    if (casIn2 = '0') then
                        general_counter <= (others => '0');
                    else
                        general_counter <= general_counter + 1;
                    end if;
                elsif (comms_mode = "01") then
                    -- Sound Mode - Frequency = 1MHz / [16 * (S + 1)]
                    if (general_counter = 0) then
                        general_counter <= counter & "00000000";
                        sound_bit <= not sound_bit;
                    else
                        general_counter <= general_counter - 1;
                    end if;
                elsif (comms_mode = "10") then
                    -- Cassette Out Mode
                    -- Bit 12 is at 2404Hz
                    -- Bit 13 is at 1202Hz
                    if (general_counter(11 downto 0) = 0) then
                        general_counter <= general_counter - x"301";
                    else
                        general_counter <= general_counter - x"001";
                    end if;
                end if;


                -- Tape Interface Receive
                casIn1 <= casIn;
                casIn2 <= casIn1;
                casIn3 <= casIn2;
                if (comms_mode = "00" and motor_int = '1') then
                    -- Only take actions on the falling edge of casIn
                    -- On the falling edge, general_counter will contain length of
                    -- the previous high pulse in 16MHz cycles.
                    -- A 1200Hz pulse is 6666 cycles
                    -- A 2400Hz pulse is 3333 cycles
                    -- A threshold in between would be 5000 cycles.
                    -- Ignore pulses shorter then say 500 cycles as these are
                    -- probably just noise.

                    if (casIn3 = '1' and casIn2 = '0' and general_counter > 500) then
                        -- a Pulse of length > 500 cycles has been detected

                        if (cindat = '0' and cintone = '0' and general_counter <= 5000) then
                            -- High Tone detected
                            cindat  <= '0';
                            cintone <= '1';
                            cinbits <= (others => '0');
                            -- Generate the high tone detect interrupt
                            isr(6) <= '1';

                        elsif (cindat = '0' and cintone = '1' and general_counter > 5000) then
                            -- Start bit detected
                            cindat  <= '1';
                            cintone <= '0';
                            cinbits <= (others => '0');

                        elsif (cindat = '1' and ignore_next = '1') then
                            -- Ignoring the second pulse in a bit at 2400Hz
                            ignore_next <= '0';

                        elsif (cindat = '1' and cinbits < 9) then

                            if (cinbits < 8) then
                                if (general_counter > 5000) then
                                    -- shift in a zero
                                    data_shift <= '0' & data_shift(7 downto 1);
                                else
                                    -- shift in a one
                                    data_shift <= '1' & data_shift(7 downto 1);
                                end if;
                                -- Generate the receive data int as soon as the
                                -- last bit has been shifted in.
                                if (cinbits = 7) then
                                    isr(4) <= '1';
                                end if;
                            end if;
                            -- Ignore the second pulse in a bit at 2400Hz
                            if (general_counter > 5000) then
                                ignore_next <= '0';
                            else
                                ignore_next <= '1';
                            end if;
                            -- Move on to the next data bit
                            cinbits <= cinbits + 1;
                        elsif (cindat = '1' and cinbits = 9) then
                            if (general_counter > 5000) then
                                -- Found next start bit...
                                cindat  <= '1';
                                cintone <= '0';
                                cinbits <= (others => '0');
                            else
                                -- Back in tone again
                                cindat  <= '0';
                                cintone <= '1';
                                cinbits <= (others => '0');
                                -- Generate the high tone detect interrupt
                                isr(6) <= '1';
                           end if;
                       end if;
                    end if;
                else
                    cindat      <= '0';
                    cintone     <= '0';
                    cinbits     <= (others => '0');
                    ignore_next <= '0';
                end if;

                -- regardless of the comms mode, update coutbits state (at 1200Hz)
                if general_counter(13 downto 0) = 0 then                            
                    -- wait to TDEmpty interrupt to be cleared before starting
                    if coutbits = 0 then
                        if isr(5) = '0' then
                            coutbits <= x"9";
                        end if;
                    else
                        -- set the TDEmpty interrpt after the last data bit is sent
                        if coutbits = 1 then
                            isr(5) <= '1';
                        end if;
                        -- shift the data shift register if not the start bit
                        -- shifting a 1 at the top end gives us the correct stop bit
                        if comms_mode = "10" and coutbits /= 9 then
                            data_shift <= '1' & data_shift(7 downto 1);
                        end if;
                        -- move to the next state
                        coutbits <= coutbits - 1;
                    end if;
                end if;
                -- Generate the cassette out tone based on the current state
                if coutbits = 9 or (coutbits > 0 and data_shift(0) = '0') then
                    -- start bit or data bit "0" = 1200Hz
                    casOut <= general_counter(13);
                else
                    -- stop bit or data bit "1" or any other time= 2400Hz
                    casOut <= general_counter(12);
                end if;                

                -- ULA Writes
                if (cpu_clken = '1') then
                    if delayed_clear_reset = '1' then
                        power_on_reset <= '0';
                    end if;
                    -- Detect control+caps 1...4 and change video format
                    if (addr = x"9fff" and page_enable = '1' and page(2 downto 1) = "00") then
                        if (kbd(2 downto 1) = "00") then
                            ctrl_caps <= '1';
                        else
                            ctrl_caps <= '0';
                        end if;
                    end if;
                    -- Detect "1" being pressed
                    if (addr = x"afff" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0') then
                        mode <= "00";
                    end if;
                    -- Detect "2" being pressed
                    if (addr = x"b7ff" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0') then
                        mode <= "01";
                    end if;
                    -- Detect "3" being pressed
                    if (addr = x"bbff" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0' and IncludeVGA) then
                        mode <= "10";
                    end if;
                    -- Detect "4" being pressed
                    if (addr = x"bdff" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0' and IncludeVGA) then
                        mode <= "11";
                    end if;
                    -- Detect "5" being pressed
                    if (addr = x"beff" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0') then
                        turbo_out <= "00";
                    end if;
                    -- Detect "6" being pressed
                    if (addr = x"bf7f" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0') then
                        turbo_out <= "01";
                    end if;
                    -- Detect "7" being pressed
                    if (addr = x"bfbf" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0') then
                        turbo_out <= "10";
                    end if;
                    -- Detect "8" being pressed
                    if (addr = x"bfdf" and page_enable = '1' and page(2 downto 1) = "00" and ctrl_caps = '1' and kbd(0) = '0') then
                        turbo_out <= "11";
                    end if;
						  if (addr = x"FC70") then -- this will set what channel of adc to read
								adc_chan <= data_in(3 downto 0);
						  end if; 
                    if (addr(15 downto 8) = x"FE") then
                        if (R_W_n = '1') then
                            -- Clear the power on reset flag on the first read of the ISR (FEx0)
                            if (addr(3 downto 0) = x"0") then
                                delayed_clear_reset <= '1';
                            end if;
                            -- Clear the RDFull interrupts on reading the data_shift register
                            if (addr(3 downto 0) = x"4") then
                                isr(4) <= '0';
                            end if;
                        else
                            case addr(3 downto 0) is
                            when x"0" =>
                                ier(6 downto 2) <= data_in(6 downto 2);
                            when x"1" =>
                            when x"2" =>
                                screen_base(8 downto 6) <= data_in(7 downto 5);
                            when x"3" =>
                                screen_base(14 downto 9) <= data_in(5 downto 0);
                            when x"4" =>
                                data_shift <= data_in;
                                -- Clear the TDEmpty interrupt on writing the
                                -- data_shift register
                                isr(5) <= '0';
                            when x"5" =>
                                if (data_in(6) = '1') then
                                    -- Clear High Tone Detect IRQ
                                    isr(6) <= '0';
                                end if;
                                if (data_in(5) = '1') then
                                    -- Clear Real Time Clock IRQ
                                    isr(3) <= '0';
                                end if;
                                if (data_in(4) = '1') then
                                    -- Clear Display End IRQ
                                    isr(2) <= '0';
                                end if;
                                if (page_enable = '1' and page(2) = '0') then
                                    -- Roms 8-11 currently selected, so only selecting 8-15 will be honoured
                                    if (data_in(3) = '1') then
                                        page_enable <= data_in(3);
                                        page <= data_in(2 downto 0);
                                    end if;
                                else
                                    -- Roms 0-7 or 12-15 currently selected, so anything goes
                                    page_enable <= data_in(3);
                                    page <= data_in(2 downto 0);
                                end if;
                            when x"6" =>
                                counter <= data_in;
                            when x"7" =>
                                caps_int     <= data_in(7);
                                motor_int    <= data_in(6);
                                case (data_in(5 downto 3)) is
                                when "000" =>
                                    mode_base    <= x"30";
                                    mode_bpp     <= "00";
                                    mode_40      <= '0';
                                    mode_text    <= '0';
                                    mode_rowstep <= std_logic_vector(to_unsigned(633, 10)); -- 640 - 7
                                when "001" =>
                                    mode_base    <= x"30";
                                    mode_bpp     <= "01";
                                    mode_40      <= '0';
                                    mode_text    <= '0';
                                    mode_rowstep <= std_logic_vector(to_unsigned(633, 10)); -- 640 - 7
                                when "010" =>
                                    mode_base    <= x"30";
                                    mode_bpp     <= "10";
                                    mode_40      <= '0';
                                    mode_text    <= '0';
                                    mode_rowstep <= std_logic_vector(to_unsigned(633, 10)); -- 640 - 7
                                when "011" =>
                                    mode_base    <= x"40";
                                    mode_bpp     <= "00";
                                    mode_40      <= '0';
                                    mode_text    <= '1';
                                    mode_rowstep <= std_logic_vector(to_unsigned(631, 10)); -- 640 - 9
                                when "100" =>
                                    mode_base    <= x"58";
                                    mode_bpp     <= "00";
                                    mode_40      <= '1';
                                    mode_text    <= '0';
                                    mode_rowstep <= std_logic_vector(to_unsigned(313, 10)); -- 320 - 7
                                when "101" =>
                                    mode_base    <= x"60";
                                    mode_bpp     <= "01";
                                    mode_40      <= '1';
                                    mode_text    <= '0';
                                    mode_rowstep <= std_logic_vector(to_unsigned(313, 10)); -- 320 - 7
                                when "110" =>
                                    mode_base    <= x"60";
                                    mode_bpp     <= "00";
                                    mode_40      <= '1';
                                    mode_text    <= '1';
                                    mode_rowstep <= std_logic_vector(to_unsigned(311, 10)); -- 320 - 9
                                when "111" =>
                                    -- mode 7 seems to default to mode 4
                                    mode_base    <= x"58";
                                    mode_bpp     <= "00";
                                    mode_40      <= '1';
                                    mode_text    <= '0';
                                    mode_rowstep <= std_logic_vector(to_unsigned(313, 10)); -- 320 - 7
                                when others =>
                                end case;
                                comms_mode   <= data_in(2 downto 1);
                                -- A quirk of the Electron ULA is that RxFull
                                -- interrupt fires when tape output mode is
                                -- entered. Games like Southen Belle rely on
                                -- this quirk.
                                if data_in(2 downto 1) = "10" then
                                    isr(4) <= '1';
                                end if;
                            when others =>
                                -- A '1' in the palatte data means disable the colour
                                -- Invert the stored palette, to make the palette logic simpler
                                palette(slv2int(addr(2 downto 0))) <= data_in xor "11111111";
                            end case;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

	 




	 
	 
    -- SGVA timing at 60Hz with a 40.000MHz Pixel Clock
    -- Horizontal 800 + 40 + 128 + 88 = total 1056
    -- Vertical   600 +  1 +   4 + 23 = total 628
    -- Within the the 640x512 is centred so starts at 80,44
    -- Horizontal 640 + (80 + 40) + 128 + (88 + 80) = total 1056
    -- Vertical   512 + (44 +  1) +   4 + (23 + 44) = total 628

    -- RGBs timing at 50Hz with a 16.000MHz Pixel Clock
    -- Horizontal 640 + (96 + 26) +  75 + (91 + 96) = total 1024
    -- Vertical   256 + (16 +  2) +   3 + (19 + 16) = total 312

    process (clk_video)
    variable pixel : std_logic_vector(3 downto 0);
    begin
        if rising_edge(clk_video) then
            -- pipeline h_count by one cycle to compensate the register in the RAM
            h_count1 <= h_count;
            if (h_count = h_total) then
                h_count <= (others => '0');
                col_offset <= (others => '0');
                if (v_count = v_total) then
                    v_count <= (others => '0');
                    char_row <= (others => '0');
                    row_offset <= (others => '0');
                    screen_base1  <= screen_base;
                    mode_base1  <= mode_base;
                    if (mode = "01") then
                        -- Interlaced, so alternate odd and even fields
                        field <= not field;
                    else
                        -- Non-interlaced, so odd fields only
                        field <= '0';
                    end if;
                else
                    v_count <= v_count + 1;
                    if (v_count(0) = '1' or mode(1) = '0') then
                        if ((mode_text = '0' and char_row = 7) or (mode_text = '1' and char_row = 9)) then
                            char_row <= (others => '0');
                            row_offset <= row_offset + mode_rowstep;
                        else
                            char_row <= char_row + 1;
                            row_offset <= row_offset + 1;
                        end if;
                    end if;
                end if;
            else
                h_count <= h_count + 1;
                if ((mode_40 = '0' and h_count(2 downto 0) = "111") or
                    (mode_40 = '1' and h_count(3 downto 0) = "1111")) then
                    col_offset <= col_offset + 8;
                end if;
            end if;
            -- RGB Data
				if (v_count >= v_display) then
					vblank <= '1';
				else
					vblank <= '0';
				end if;
				if (h_count1 >= h_active) then
					hblank <= '1';
				else
					hblank <= '0';
				end if;
				
				
				
				
            if (h_count1 >= h_active or (mode_text = '0' and v_count >= v_active_gph) or (mode_text = '1' and v_count >= v_active_txt) or char_row >= 8) then
                -- blanking and border are always black
                red_int   <= (others => '0');
                green_int <= (others => '0');
                blue_int  <= (others => '0');

                contention <= '0';
            else

                -- Indicate possible memory contention on active scan lines
                contention <= not mode_40;
                -- rendering an actual pixel
                if (mode_bpp = 0) then
                    -- 1 bit per pixel, map to colours 0 and 8 for the palette lookup
                    if (mode_40 = '1') then
                        pixel := screen_data(7 - slv2int(h_count1(3 downto 1))) & "000";
                    else
                        pixel := screen_data(7 - slv2int(h_count1(2 downto 0))) & "000";
                    end if;
                elsif (mode_bpp = 1) then
                    -- 2 bits per pixel, map to colours 0, 2, 8, 10 for the palette lookup
                    if (mode_40 = '1') then
                        pixel := screen_data(7 - slv2int(h_count1(3 downto 2))) & "0" &
                                 screen_data(3 - slv2int(h_count1(3 downto 2))) & "0";
                    else
                        pixel := screen_data(7 - slv2int(h_count1(2 downto 1))) & "0" &
                                 screen_data(3 - slv2int(h_count1(2 downto 1))) & "0";
                    end if;
                else
                    -- 4 bits per pixel, map directly for the palette lookup
                    if (mode_40 = '1') then
                        pixel := screen_data(7 - sl2int(h_count1(3))) &
                                 screen_data(5 - sl2int(h_count1(3))) &
                                 screen_data(3 - sl2int(h_count1(3))) &
                                 screen_data(1 - sl2int(h_count1(3)));
                    else
                        pixel := screen_data(7 - sl2int(h_count1(2))) &
                                 screen_data(5 - sl2int(h_count1(2))) &
                                 screen_data(3 - sl2int(h_count1(2))) &
                                 screen_data(1 - sl2int(h_count1(2)));
                    end if;
                end if;
                -- Implement Color Palette
                case (pixel) is
                when "0000" =>
                    red_int   <= (others => palette(1)(0));
                    green_int <= (others => palette(1)(4));
                    blue_int  <= (others => palette(0)(4));
                when "0001" =>
                    red_int   <= (others => palette(7)(0));
                    green_int <= (others => palette(7)(4));
                    blue_int  <= (others => palette(6)(4));
                when "0010" =>
                    red_int   <= (others => palette(1)(1));
                    green_int <= (others => palette(1)(5));
                    blue_int  <= (others => palette(0)(5));
                when "0011" =>
                    red_int   <= (others => palette(7)(1));
                    green_int <= (others => palette(7)(5));
                    blue_int  <= (others => palette(6)(5));
                when "0100" =>
                    red_int   <= (others => palette(3)(0));
                    green_int <= (others => palette(3)(4));
                    blue_int  <= (others => palette(2)(4));
                when "0101" =>
                    red_int   <= (others => palette(5)(0));
                    green_int <= (others => palette(5)(4));
                    blue_int  <= (others => palette(4)(4));
                when "0110" =>
                    red_int   <= (others => palette(3)(1));
                    green_int <= (others => palette(3)(5));
                    blue_int  <= (others => palette(2)(5));
                when "0111" =>
                    red_int   <= (others => palette(5)(1));
                    green_int <= (others => palette(5)(5));
                    blue_int  <= (others => palette(4)(5));
                when "1000" =>
                    red_int   <= (others => palette(1)(2));
                    green_int <= (others => palette(0)(2));
                    blue_int  <= (others => palette(0)(6));
                when "1001" =>
                    red_int   <= (others => palette(7)(2));
                    green_int <= (others => palette(6)(2));
                    blue_int  <= (others => palette(6)(6));
                when "1010" =>
                    red_int   <= (others => palette(1)(3));
                    green_int <= (others => palette(0)(3));
                    blue_int  <= (others => palette(0)(7));
                when "1011" =>
                    red_int   <= (others => palette(7)(3));
                    green_int <= (others => palette(6)(3));
                    blue_int  <= (others => palette(6)(7));
                when "1100" =>
                    red_int   <= (others => palette(3)(2));
                    green_int <= (others => palette(2)(2));
                    blue_int  <= (others => palette(2)(6));
                when "1101" =>
                    red_int   <= (others => palette(5)(2));
                    green_int <= (others => palette(4)(2));
                    blue_int  <= (others => palette(4)(6));
                when "1110" =>
                    red_int   <= (others => palette(3)(3));
                    green_int <= (others => palette(2)(3));
                    blue_int  <= (others => palette(2)(7));
                when "1111" =>
                    red_int   <= (others => palette(5)(3));
                    green_int <= (others => palette(4)(3));
                    blue_int  <= (others => palette(4)(7));
                when others =>
                end case;
            end if;
            -- Vertical Sync
            if (field = '0') then
                -- first field of interlaced scanning (or non interlaced)
                -- vsync starts at the begging of the line
                if (h_count1 = 0) then
                    if (v_count = vsync_start) then
                        vsync_int <= '0';
                    elsif (v_count = vsync_end) then
                        vsync_int <= '1';
                    end if;
                end if;
            else
                -- second field of intelaced scanning
                -- vsync starts half way through the line
                if (h_count1 = ('0' & h_total(10 downto 1))) then
                    if (v_count = vsync_start) then
                        vsync_int <= '0';
                    elsif (v_count = vsync_end) then
                        vsync_int <= '1';
                    end if;
                end if;
            end if;
            -- Horizontal Sync
            if (h_count1 = hsync_start) then
                hsync_int <= '0';
                if (v_count = v_display) then
                    display_intr <= '1';
                end if;
                if (v_count = v_rtc) then
                    rtc_intr <= '1';
                end if;
            elsif (h_count1 = hsync_end) then
                hsync_int    <= '1';
                display_intr <= '0';
                rtc_intr     <= '0';
            end if;
        end if;
    end process;

    process (screen_base1, mode_base1, row_offset, col_offset, crtc_ma, mode7_enable)
        variable tmp: std_logic_vector(15 downto 0);
    begin
        tmp := ("0" & screen_base1 & "000000") + row_offset + col_offset;
        if (tmp(15) = '1') then
            tmp := tmp + (mode_base1 & "00000000");
        end if;
        if mode7_enable = '1' then
            screen_addr <= "11111" & crtc_ma(9 downto 0);
        else
            screen_addr <= tmp(14 downto 0);
        end if;
    end process;

    red   <= (others => ttxt_r_out) when mode7_enable = '1' else
             red_int;

    green <= (others => ttxt_g_out) when mode7_enable = '1' else
             green_int;

    blue  <= (others => ttxt_b_out) when mode7_enable = '1' else
             blue_int;

	h_cnt<=h_count;
	v_cnt<=v_count;
	 -- alanswx -- for some reason this code set's vsync to 1 when it is in
	 -- 15khz mode, which breaks the MiSTer scaler. For now we are just going to
	 -- get rid of the logic.
				 
    --vsync <= ttxt_vs_out when mode7_enable = '1' else
    --         '1' when mode(1) = '0' else
    --         vsync_int;
    vsync <= vsync_int;

    --hsync <= ttxt_hs_out when mode7_enable = '1' else
    --         hsync_int and vsync_int when mode(1) = '0' else
    --         hsync_int;
    hsync <= hsync_int;

    caps  <= caps_int;
    motor <= motor_int;

--------------------------------------------------------
-- clock enable generator
--------------------------------------------------------

    -- ROM accesses always happen at 2Mhz
    rom_access <= not ROM_n_int;
    -- RAM accesses always happen at 1Mhz and subber contention
    ram_access <= not addr(15);
    -- IO accesses always happen at 1MHz and don't suffer contention

    clk_gen1 : process(clk_16M00, RST_n)
    begin
        if rising_edge(clk_16M00) then
            -- clock state machine
            if clken_counter(0) = '1' and clken_counter(1) = '1' then
                case clk_state is
                when "000" =>
                    if rom_access = '1' then
                        -- 2MHz no contention
                        clk_state <= "001";
                    else
                        -- 1MHz, possible contention
                        clk_state <= "101";
                    end if;
                when "001" =>
                    -- CPU is clocked in this state
                    clk_state <= "010";
                when "010" =>
                    if rom_access = '1' then
                        -- 2MHz no contention
                        clk_state <= "011";
                    else
                        -- 1MHz, possible contention
                        clk_state <= "111";
                    end if;
                when "011" =>
                    -- CPU is clocked in this state
                    clk_state <= "000";
                when "100" =>
                    clk_state <= "101";
                when "101" =>
                    clk_state <= "110";
                when "110" =>
                    if ram_access = '1' and contention2 = '1' then
                        clk_state <= "111";
                    else
                        clk_state <= "011";
                    end if;
                when "111" =>
                    clk_state <= "100";
                when others => null;
                end case;
            end if;
            -- clken counter
            clken_counter <= clken_counter + 1;
            -- Synchronize contention signal
            contention1 <= contention;
            contention2 <= contention1;
            -- 1MHz
            -- cpu_clken active on cycle 0
            -- address/data changes on cycle 1
            cpu_clken_1  <= clken_counter(0) and clken_counter(1) and clken_counter(2) and clken_counter(3);
            via1_clken_1 <= clken_counter(3);
				via2_clken_1 <= clken_counter(2);
            -- 2MHz
            -- cpu_clken active on cycle 0, 8
            -- address/data changes on cycle 1, 9
            cpu_clken_2  <= clken_counter(0) and clken_counter(1) and clken_counter(2);
            via1_clken_2 <= clken_counter(2);
				via2_clken_2 <= clken_counter(1);
            -- 4MHz - no contention
            -- cpu_clken active on cycle 0, 4, 8, 12
            -- address/data changes on cycle 1, 5, 9, 13
            cpu_clken_4  <= clken_counter(0) and clken_counter(1);
            via1_clken_4 <= clken_counter(1);
				via2_clken_4 <= clken_counter(0);
        end if;
    end process;

    clk_gen2 : process(turbo, clken_counter, clk_state,
                       cpu_clken_1, cpu_clken_2, cpu_clken_4,
                       via1_clken_1, via1_clken_2, via1_clken_4,
							  via2_clken_1, via2_clken_2, via2_clken_4)
    begin
        case (turbo) is
            when "01" =>
                -- 2Mhz Contention
                cpu_clken <= '0';
                via1_clken <= '0';
					 via2_clken <= '0';
                if clken_counter(0) = '1' and clken_counter(1) = '1' then
                    -- 1MHz/2MHz/Stopped
                    if clk_state = "001" or clk_state = "011" then
                        cpu_clken <= '1';
                    end if;
                    -- 1MHz fixed
                    --if clk_state = "011" or clk_state = "111" then
                    --    via1_clken <= '1';
                    --end if;
                    via1_clken <= clk_state(1);
						  via2_clken <= clk_state(0);
                end if;
            when "10" =>
                -- 2Mhz No Contention
                cpu_clken  <= cpu_clken_2;
                via1_clken <= via1_clken_2;
					 via2_clken <= via2_clken_2;
            when "11" =>
                -- 4MHz No contention
                cpu_clken  <= cpu_clken_4;
                via1_clken <= via1_clken_4;
					 via2_clken <= via2_clken_4;
            when others =>
                -- 1MHz No Contention
                cpu_clken  <= cpu_clken_1;
                via1_clken <= via1_clken_1;
					 via2_clken <= via2_clken_1;
        end case;
    end process;

    cpu_clken_out  <= cpu_clken;

--------------------------------------------------------
-- Optional MMC Filing System
--------------------------------------------------------

        mc6522_enable  <= '1' when addr(15 downto 4) = x"fcb" else '0';

			via : work.via6522 port map (
				clock       => clk_16M00,
				rising      => via2_clken and     via1_clken,
				falling     => via2_clken and not via1_clken,
				reset       => not RST_n,
				addr        => addr(3 downto 0),
				wen         => mc6522_enable and not R_W_n,
				ren         => mc6522_enable and     R_W_n,
				data_in     => data_in(7 downto 0),
				data_out    => mc6522_data(7 downto 0),
				port_a_i    => mc6522_porta,
				port_a_o    => mc6522_porta,
				port_a_t    => open,
				port_b_i    => mc6522_portb_in,
				port_b_o    => mc6522_portb_out,
				port_b_t    => mc6522_portb_oe,
				ca1_i       => '0',
				ca2_i       => mc6522_ca2,
				ca2_o       => mc6522_ca2,
				ca2_t       => open,
				cb1_i       => mc6522_cb1_in,
				cb1_o       => mc6522_cb1_out,
				cb1_t       => mc6522_cb1_oe,
				cb2_i       => mc6522_cb2_in,
				cb2_o       => open,
				cb2_t       => open,
				irq         => mc6522_irq
			);

        -- loop back data port
        mc6522_portb_in <= mc6522_portb_out;

        -- SDCLK is driven from either PB1 or CB1 depending on the SR Mode
        sdclk_int     <= mc6522_portb_out(1) when mc6522_portb_oe(1) = '1' else
                         mc6522_cb1_out      when mc6522_cb1_oe = '1' else
                         '1';
        SDCLK         <= sdclk_int;
        mc6522_cb1_in <= sdclk_int;

        -- SDMOSI is always driven from PB0
        SDMOSI        <= mc6522_portb_out(0) when mc6522_portb_oe(0) = '1' else
                     '1';
        -- SDMISO is always read from CB2
        mc6522_cb2_in <= SDMISO;

        -- SDSS is hardwired to 0 (always selected) as there is only one slave attached
        SDSS          <= '0';

        IRQ_n <= ula_irq_n and not mc6522_irq;





        -- disable mode 7
        mode7_enable <= '0';

-- JOYSTICK HANDLING - emulation of joystick part of Plus 1
-- from https://github.com/Sector14/acorn-electron-core
-- Gary Preston <gary@mups.co.uk>
adc : process(clk_16M00, RST_n)
    begin
        if rising_edge(clk_16M00) then
	  if (addr = x"FC70") then -- read or write and we clear the interrupt
		plus_1_adc_n_intr <= '1';
	  else
		plus_1_adc_n_intr <= '0';
	  end if; 
			
	  --
	  --  Do we need to delay the joystick?
	  --

          case adc_chan is 
            -- joy1
            when "0100" => -- ch1 p15 X
	  		  plus_1_adc_data   <=joystick1_x;
            when "0101" => -- ch2 p7  Y            
	  		  plus_1_adc_data   <=joystick1_y;
						  
            -- joy2
            when "0110" => -- ch3 p12 X
	  		  plus_1_adc_data   <=joystick2_x;
            when "0111" => -- ch4 p4  Y
	  		  plus_1_adc_data   <=joystick2_y;
            when others => 
              -- No other mode supported
              plus_1_adc_data <= x"80"; 
          end case;
	end if;
     end process;

plus_1_stat_reg <= '1' & plus_1_adc_n_intr &joystick2_fire & joystick1_fire &"0000";


		  
end behavioral;
