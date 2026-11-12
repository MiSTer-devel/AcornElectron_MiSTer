-- Simulation stand-in for rtl/RAM_32k_DualPort.vhd (altsyncram BIDIR_DUAL_PORT,
-- unregistered outputs, NEW_DATA read-during-write, powers up zero).
-- Port B is read-only in ElectronULA (wren_b => '0'), so only port A writes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity RAM_32k_DualPort is
    port (
        address_a : in  std_logic_vector(14 downto 0);
        address_b : in  std_logic_vector(14 downto 0);
        clock_a   : in  std_logic := '1';
        clock_b   : in  std_logic;
        data_a    : in  std_logic_vector(7 downto 0);
        data_b    : in  std_logic_vector(7 downto 0);
        wren_a    : in  std_logic := '0';
        wren_b    : in  std_logic := '0';
        q_a       : out std_logic_vector(7 downto 0);
        q_b       : out std_logic_vector(7 downto 0)
    );
end RAM_32k_DualPort;

architecture sim of RAM_32k_DualPort is
    type mem_t is array(0 to 32767) of std_logic_vector(7 downto 0);
    signal mem : mem_t := (others => (others => '0'));
begin
    process(clock_a)
    begin
        if rising_edge(clock_a) then
            if wren_a = '1' then
                mem(to_integer(unsigned(address_a))) <= data_a;
                q_a <= data_a;
            else
                q_a <= mem(to_integer(unsigned(address_a)));
            end if;
        end if;
    end process;

    process(clock_b)
    begin
        if rising_edge(clock_b) then
            q_b <= mem(to_integer(unsigned(address_b)));
        end if;
    end process;
end sim;
