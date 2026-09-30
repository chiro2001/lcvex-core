	component sfl_sys is
		port (
			clk_in_clk_clk             : in  std_logic                     := 'X';             -- clk
			epcq_avl_csr_read          : in  std_logic                     := 'X';             -- read
			epcq_avl_csr_waitrequest   : out std_logic;                                        -- waitrequest
			epcq_avl_csr_write         : in  std_logic                     := 'X';             -- write
			epcq_avl_csr_address       : in  std_logic_vector(2 downto 0)  := (others => 'X'); -- address
			epcq_avl_csr_writedata     : in  std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			epcq_avl_csr_readdata      : out std_logic_vector(31 downto 0);                    -- readdata
			epcq_avl_csr_readdatavalid : out std_logic;                                        -- readdatavalid
			epcq_avl_mem_write         : in  std_logic                     := 'X';             -- write
			epcq_avl_mem_burstcount    : in  std_logic_vector(6 downto 0)  := (others => 'X'); -- burstcount
			epcq_avl_mem_waitrequest   : out std_logic;                                        -- waitrequest
			epcq_avl_mem_read          : in  std_logic                     := 'X';             -- read
			epcq_avl_mem_address       : in  std_logic_vector(24 downto 0) := (others => 'X'); -- address
			epcq_avl_mem_writedata     : in  std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			epcq_avl_mem_readdata      : out std_logic_vector(31 downto 0);                    -- readdata
			epcq_avl_mem_readdatavalid : out std_logic;                                        -- readdatavalid
			epcq_avl_mem_byteenable    : in  std_logic_vector(3 downto 0)  := (others => 'X'); -- byteenable
			rst_in_reset_reset         : in  std_logic                     := 'X'              -- reset
		);
	end component sfl_sys;

	u0 : component sfl_sys
		port map (
			clk_in_clk_clk             => CONNECTED_TO_clk_in_clk_clk,             --   clk_in_clk.clk
			epcq_avl_csr_read          => CONNECTED_TO_epcq_avl_csr_read,          -- epcq_avl_csr.read
			epcq_avl_csr_waitrequest   => CONNECTED_TO_epcq_avl_csr_waitrequest,   --             .waitrequest
			epcq_avl_csr_write         => CONNECTED_TO_epcq_avl_csr_write,         --             .write
			epcq_avl_csr_address       => CONNECTED_TO_epcq_avl_csr_address,       --             .address
			epcq_avl_csr_writedata     => CONNECTED_TO_epcq_avl_csr_writedata,     --             .writedata
			epcq_avl_csr_readdata      => CONNECTED_TO_epcq_avl_csr_readdata,      --             .readdata
			epcq_avl_csr_readdatavalid => CONNECTED_TO_epcq_avl_csr_readdatavalid, --             .readdatavalid
			epcq_avl_mem_write         => CONNECTED_TO_epcq_avl_mem_write,         -- epcq_avl_mem.write
			epcq_avl_mem_burstcount    => CONNECTED_TO_epcq_avl_mem_burstcount,    --             .burstcount
			epcq_avl_mem_waitrequest   => CONNECTED_TO_epcq_avl_mem_waitrequest,   --             .waitrequest
			epcq_avl_mem_read          => CONNECTED_TO_epcq_avl_mem_read,          --             .read
			epcq_avl_mem_address       => CONNECTED_TO_epcq_avl_mem_address,       --             .address
			epcq_avl_mem_writedata     => CONNECTED_TO_epcq_avl_mem_writedata,     --             .writedata
			epcq_avl_mem_readdata      => CONNECTED_TO_epcq_avl_mem_readdata,      --             .readdata
			epcq_avl_mem_readdatavalid => CONNECTED_TO_epcq_avl_mem_readdatavalid, --             .readdatavalid
			epcq_avl_mem_byteenable    => CONNECTED_TO_epcq_avl_mem_byteenable,    --             .byteenable
			rst_in_reset_reset         => CONNECTED_TO_rst_in_reset_reset          -- rst_in_reset.reset
		);
