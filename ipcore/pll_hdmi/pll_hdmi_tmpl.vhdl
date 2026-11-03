-- Created by IP Generator (Version 2022.2-SP3 build 127103)
-- Instantiation Template
--
-- Insert the following codes into your VHDL file.
--   * Change the_instance_name to your own instance name.
--   * Change the net names in the port map.


COMPONENT pll_hdmi
  PORT (
    clkout1 : OUT STD_LOGIC;
    clkout2 : OUT STD_LOGIC;
    lock : OUT STD_LOGIC;
    clkin1 : IN STD_LOGIC
  );
END COMPONENT;


the_instance_name : pll_hdmi
  PORT MAP (
    clkout1 => clkout1,
    clkout2 => clkout2,
    lock => lock,
    clkin1 => clkin1
  );
