// 27 MHz sistem saati (Periyot = 37.037 ns)
create_clock -name clk_27m -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]

// OV7670 PCLK girişi (Maksimum ~13.5 MHz, Periyot = 74.074 ns)
create_clock -name cam_pclk -period 74.074 -waveform {0 37.037} [get_ports {cam_pclk}]

// Farklı saat alanları (asenkron)
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {cam_pclk}]
