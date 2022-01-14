library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity keyboard is
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        ps2_key    : in  std_logic_vector(10 downto 0);
--        ps2_data   : in  std_logic;
        col        : out std_logic_vector(3 downto 0);
        row        : in  std_logic_vector(13 downto 0);
        break      : out std_logic;
        turbo      : out std_logic_vector(1 downto 0)
        );
end entity;

architecture rtl of keyboard is

    type   key_matrix is array(0 to 13) of std_logic_vector(3 downto 0);
    signal keys       : key_matrix;
    signal press    : std_logic;

    signal keyb_data  : std_logic_vector(7 downto 0);
    signal keyb_valid : std_logic;
    signal flg : std_logic;
    
begin

    process(keys, row)
        variable i    : integer;
        variable tmp  : std_logic_vector(3 downto 0);
    begin
        tmp := "1111";
        for i in 0 to 13 loop
            if (row(i) = '0') then
                tmp := tmp and keys(i);
            end if;
        end loop;
        col <= tmp;
    end process;
	
	keyb_data <= PS2_KEY(7 downto 0);
	press <= PS2_KEY(9);
	keyb_valid <= '1' when flg /= PS2_KEY(10) else '0';
	process(clk) begin
		if rising_edge(clk) then
			flg <= PS2_KEY(10);
		end if;
	end process;

    process(clk, rst_n)
    begin
        if rst_n = '0' then

            turbo    <= "01"; -- 2MHz
            break    <= '1';
            keys( 0) <= (others => '1');
            keys( 1) <= (others => '1');
            keys( 2) <= (others => '1');
            keys( 3) <= (others => '1');
            keys( 4) <= (others => '1');
            keys( 5) <= (others => '1');
            keys( 6) <= (others => '1');
            keys( 7) <= (others => '1');
            keys( 8) <= (others => '1');
            keys( 9) <= (others => '1');
            keys(10) <= (others => '1');
            keys(11) <= (others => '1');
            keys(12) <= (others => '1');
            keys(13) <= (others => '1');

        elsif rising_edge(clk) then
		  
				-- To stop Quartus inferring latches
				keys(0)(2) <= '1';
				keys(2)(3) <= '1';
                    
            if keyb_valid = '1' then
               
                    
                    case keyb_data is
                        -- Special keys
                        when X"05" => turbo       <= "00";     -- F1 (1MHz)
                        when X"06" => turbo       <= "01";     -- F2 (2MMz)
                        when X"04" => turbo       <= "10";     -- F3 (4MHz)
                        when X"0C" => turbo       <= "11";     -- F4 (8MHz)
                        when X"09" => break       <= not press;  -- F10 (BREAK)
                        -- Key Matrix
                        when X"74" => keys( 0)(0) <= not press;  -- RIGHT           
                        when X"69" => keys( 0)(1) <= not press;  -- END (COPY)
                        --            keys( 0)(2)              -- NC
                        when X"29" => keys( 0)(3) <= not press;  -- SPACE

                        when X"6B" => keys( 1)(0) <= not press;  -- LEFT
                        when X"72" => keys( 1)(1) <= not press;  -- DOWN
                        when X"5B" => keys( 1)(1) <= not press;  -- ]
                        when X"5A" => keys( 1)(2) <= not press;  -- RETURN
                        when X"66" => keys( 1)(3) <= not press;  -- BACKSPACE (DELETE)

                        when X"4E" => keys( 2)(0) <= not press;  -- -                                      
                        when X"75" => keys( 2)(1) <= not press;  -- UP
                        when X"54" => keys( 2)(1) <= not press;  -- [       
                        when X"52" => keys( 2)(2) <= not press;  -- '   full colon substitute
                        --            keys( 2)(3)              -- NC

                        when X"45" => keys( 3)(0) <= not press;  -- 0
                        when X"4D" => keys( 3)(1) <= not press;  -- P
                        when X"4C" => keys( 3)(2) <= not press;  -- ;
                        when X"4A" => keys( 3)(3) <= not press;  -- /

                        when X"46" => keys( 4)(0) <= not press;  -- 9
                        when X"44" => keys( 4)(1) <= not press;  -- O
                        when X"4B" => keys( 4)(2) <= not press;  -- L
                        when X"49" => keys( 4)(3) <= not press;  -- .
                                      
                        when X"3E" => keys( 5)(0) <= not press;  -- 8                               
                        when X"43" => keys( 5)(1) <= not press;  -- I
                        when X"42" => keys( 5)(2) <= not press;  -- K
                        when X"41" => keys( 5)(3) <= not press;  -- ,       

                        when X"3D" => keys( 6)(0) <= not press;  -- 7               
                        when X"3C" => keys( 6)(1) <= not press;  -- U
                        when X"3B" => keys( 6)(2) <= not press;  -- J                                       
                        when X"3A" => keys( 6)(3) <= not press;  -- M
                                      
                        when X"36" => keys( 7)(0) <= not press;  -- 6
                        when X"35" => keys( 7)(1) <= not press;  -- Y
                        when X"33" => keys( 7)(2) <= not press;  -- H                                      
                        when X"31" => keys( 7)(3) <= not press;  -- N

                        when X"2E" => keys( 8)(0) <= not press;  -- 5                                       
                        when X"2C" => keys( 8)(1) <= not press;  -- T
                        when X"34" => keys( 8)(2) <= not press;  -- G
                        when X"32" => keys( 8)(3) <= not press;  -- B

                        when X"25" => keys( 9)(0) <= not press;  -- 4
                        when X"2D" => keys( 9)(1) <= not press;  -- R
                        when X"2B" => keys( 9)(2) <= not press;  -- F
                        when X"2A" => keys( 9)(3) <= not press;  -- V

                        when X"26" => keys(10)(0) <= not press;  -- 3
                        when X"24" => keys(10)(1) <= not press;  -- E       
                        when X"23" => keys(10)(2) <= not press;  -- D
                        when X"21" => keys(10)(3) <= not press;  -- C

                        when X"1E" => keys(11)(0) <= not press;  -- 2
                        when X"1D" => keys(11)(1) <= not press;  -- W
                        when X"1B" => keys(11)(2) <= not press;  -- S
                        when X"22" => keys(11)(3) <= not press;  -- X

                        when X"16" => keys(12)(0) <= not press;  -- 1
                        when X"15" => keys(12)(1) <= not press;  -- Q
                        when X"1C" => keys(12)(2) <= not press;  -- A
                        when X"1A" => keys(12)(3) <= not press;  -- Z

                        when X"76" => keys(13)(0) <= not press;  -- ESCAPE
                        when X"58" => keys(13)(1) <= not press;  -- CAPS LOCK
                        when X"14" => keys(13)(2) <= not press;  -- LEFT/RIGHT CTRL (CTRL)                                       
                        when X"12" => keys(13)(3) <= not press;  -- Left SHIFT
						when X"59" => keys(13)(3) <= not press;  -- Right SHIFT

                        when others => null;
                    end case;
                    
 
            end if;
        end if;
    end process;
    
end architecture;


