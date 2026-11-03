-- Created by IP Generator (Version 2022.2-SP3 build 127103)
-- Instantiation Template
--
-- Insert the following codes into your VHDL file.
--   * Change the_instance_name to your own instance name.
--   * Change the net names in the port map.


COMPONENT pll_cfg
  PORT (
    clkout0 : OUT STD_LOGIC;
    lock : OUT STD_LOGIC;
    clkin1 : IN STD_LOGIC
  );
END COMPONENT;


the_instance_name : pll_cfg
  PORT MAP (
    clkout0 => clkout0,
    lock => lock,
    clkin1 => clkin1
  );
