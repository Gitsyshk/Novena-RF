------------------------------------------------------------------------
-- Configurable half-band filter chain:
--
--  * Interpolation and decimation supported.
--  * Select sample rate with bypasses selection.
--  * Configurable number of filters in chain.
--
-- TODO we have generated a single 11-tap interp and decim FIR filter
-- for all filters in the chain. This is not the best use of resources:
-- filters at lower rates can have more taps and more cycles.
--
-- Copyright (c) 2015-2015 Lime Microsystems
-- Copyright (c) 2015-2015 Andrew "bunnie" Huang
-- SPDX-License-Identifier: Apache-2.0
-- http://www.apache.org/licenses/LICENSE-2.0
------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hb_filter_chain is
    generic(
        -- the number of filters in the chain
        NUM_FILTERS : natural := 4;

        -- mode: "interp" or "decim"
        MODE : string := "interp"
    );
    port(
        -- The clock domain used for all interfaces.
        clk : in std_logic;

        -- synchronous reset
        rst : in std_logic;

        -- CORDIC phase increment
        phase_inc : in std_logic_vector(31 downto 0);

        --configuration bypasses (1 = bypass, 0 = half-band)
        --index 0 = closest to the input
        --index N-1 = closest to the output
        bypass : in std_logic_vector(NUM_FILTERS-1 downto 0);

        -- input bus interface
        in_tdata : in std_logic_vector(31 downto 0);
        in_tvalid : in std_logic;
        in_tready : out std_logic;

        -- output bus interface
        out_tdata : out std_logic_vector(31 downto 0);
        out_tvalid : out std_logic;
        out_tready : in std_logic
    );
end entity hb_filter_chain;

architecture rtl of hb_filter_chain is

    --cordic phase accumulator
    signal phase_accum : unsigned(31 downto 0);
    signal phase_tdata : std_logic_vector(15 downto 0);
    signal phase_tvalid : std_logic;
    signal phase_tready : std_logic;

    --cordic streams
    signal in_cordic_data : std_logic_vector(31 downto 0);
    signal in_cordic_valid : std_logic;
    signal in_cordic_ready : std_logic;
    signal out_cordic_data : std_logic_vector(31 downto 0);
    signal out_cordic_valid : std_logic;
    signal out_cordic_ready : std_logic;

    --intermediate signals
    signal datas : std_logic_vector((NUM_FILTERS*32) + 31 downto 0);
    signal valids : std_logic_vector(NUM_FILTERS downto 0);
    signal readies : std_logic_vector(NUM_FILTERS downto 0);

begin

    --cordic phase tracking
    --FIXME this isnt correct for scaled radians mode
    process (clk) begin
    if (rising_edge(clk)) then
        phase_tdata(15 downto 0) <= std_logic_vector(phase_accum(31 downto 16));
        phase_tvalid <= '1';
        if (rst = '1') then
            phase_accum <= to_unsigned(0, phase_accum'length);
        elsif (phase_tvalid = '1' and phase_tready = '1') then
            phase_accum <= phase_accum + unsigned(phase_inc);
        end if;
    end if;
    end process;

    --instantiate cordic
    cordic: entity work.cordic_v5_0
    port map (
        aclk => clk,
        s_axis_phase_tvalid => phase_tvalid,
        s_axis_phase_tready => phase_tready,
        s_axis_phase_tdata => phase_tdata,
        s_axis_cartesian_tvalid => in_cordic_valid,
        s_axis_cartesian_tready => in_cordic_ready,
        s_axis_cartesian_tdata => in_cordic_data,
        m_axis_dout_tvalid => out_cordic_valid,
        m_axis_dout_tready => out_cordic_ready,
        m_axis_dout_tdata => out_cordic_data
    );

    --interp mode has cordic on the output
    interp_ios: if MODE = "interp" generate

        --connect input to chain start
        datas(31 downto 0) <= in_tdata;
        valids(0) <= in_tvalid;
        in_tready <= readies(0);

        --connect chain end to cordic
        in_cordic_data <= datas((NUM_FILTERS*32) + 31 downto (NUM_FILTERS*32));
        in_cordic_valid <= valids(NUM_FILTERS);
        readies(NUM_FILTERS) <= in_cordic_ready;

        --connect cordic to output
        out_tdata <= out_cordic_data;
        out_tvalid <= out_cordic_valid;
        out_cordic_ready <= out_tready;

    end generate interp_ios;

    --decim mode has cordic on the input
    decim_ios: if MODE = "decim" generate

        --connect input to cordic
        in_cordic_data <= in_tdata;
        in_cordic_valid <= in_tvalid;
        in_tready <= in_cordic_ready;

        --connect cordic to chain start
        datas(31 downto 0) <= out_cordic_data;
        valids(0) <= out_cordic_valid;
        out_cordic_ready <= readies(0);

        --connect chain end to output
        out_tdata <= datas((NUM_FILTERS*32) + 31 downto (NUM_FILTERS*32));
        out_tvalid <= valids(NUM_FILTERS);
        readies(NUM_FILTERS) <= out_tready;

    end generate decim_ios;

    gen_filters: for i in 0 to NUM_FILTERS-1 generate
        signal in_filter_data : std_logic_vector(31 downto 0);
        signal in_filter_ready : std_logic;
        signal in_filter_valid : std_logic;
        signal out_filter_data : std_logic_vector(31 downto 0);
        signal out_filter_data_2x : std_logic_vector(31 downto 0);
        signal out_filter_ready : std_logic;
        signal out_filter_valid : std_logic;
    begin

        in_filter_data <= datas((i*32) + 31 downto (i*32));
        in_filter_valid <= valids(i) when (bypass(i) = '0') else '0';
        out_filter_ready <= readies(i+1) when (bypass(i) = '0') else '0';

        datas(((i+1)*32) + 31 downto ((i+1)*32)) <= out_filter_data_2x when (bypass(i) = '0') else in_filter_data;
        valids(i+1) <= out_filter_valid when (bypass(i) = '0') else valids(i);
        readies(i) <= in_filter_ready when (bypass(i) = '0') else readies(i+1);

        --shift up for filter loss
        out_filter_data_2x(31 downto 17) <= out_filter_data(30 downto 16);
        out_filter_data_2x(16) <= '0';
        out_filter_data_2x(15 downto 1) <= out_filter_data(14 downto 0);
        out_filter_data_2x(0) <= '0';

    interp_gen: if MODE = "interp" generate
        interp : entity work.half_band_interp
        port map (
            aclk => clk,
            s_axis_data_tdata => in_filter_data,
            s_axis_data_tvalid => in_filter_valid,
            s_axis_data_tready => in_filter_ready,
            m_axis_data_tdata => out_filter_data,
            m_axis_data_tvalid => out_filter_valid,
            m_axis_data_tready => out_filter_ready
        );
    end generate interp_gen;

    decim_gen: if MODE = "decim" generate
        decim : entity work.half_band_decim
        port map (
            aclk => clk,
            s_axis_data_tdata => in_filter_data,
            s_axis_data_tvalid => in_filter_valid,
            s_axis_data_tready => in_filter_ready,
            m_axis_data_tdata => out_filter_data,
            m_axis_data_tvalid => out_filter_valid,
            m_axis_data_tready => out_filter_ready
        );
    end generate decim_gen;

    end generate gen_filters;

end architecture rtl;
