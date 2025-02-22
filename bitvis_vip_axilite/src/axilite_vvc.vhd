--================================================================================================================================
-- Copyright 2020 Bitvis
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 and in the provided LICENSE.TXT.
--
-- Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
-- an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and limitations under the License.
--================================================================================================================================
-- Note : Any functionality not explicitly described in the documentation is subject to change at any time
----------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------
-- Description   : See library quick reference (under 'doc') and README-file(s)
------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library uvvm_vvc_framework;
use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_scoreboard;
use bitvis_vip_scoreboard.generic_sb_support_pkg.C_SB_CONFIG_DEFAULT;

use work.axilite_bfm_pkg.all;
use work.axilite_channel_handler_pkg.all;
use work.vvc_methods_pkg.all;
use work.vvc_cmd_pkg.all;
use work.td_target_support_pkg.all;
use work.td_vvc_entity_support_pkg.all;
use work.td_cmd_queue_pkg.all;
use work.td_result_queue_pkg.all;
use work.transaction_pkg.all;

--=================================================================================================
entity axilite_vvc is
  generic(
    GC_ADDR_WIDTH                            : integer range 1 to C_VVC_CMD_ADDR_MAX_LENGTH := 8;
    GC_DATA_WIDTH                            : integer range 1 to C_VVC_CMD_DATA_MAX_LENGTH := 32;
    GC_INSTANCE_IDX                          : natural                                      := 1; -- Instance index for this AXILITE_VVCT instance
    GC_AXILITE_CONFIG                        : t_axilite_bfm_config                         := C_AXILITE_BFM_CONFIG_DEFAULT; -- Behavior specification for BFM
    GC_CMD_QUEUE_COUNT_MAX                   : natural                                      := C_CMD_QUEUE_COUNT_MAX;
    GC_CMD_QUEUE_COUNT_THRESHOLD             : natural                                      := C_CMD_QUEUE_COUNT_THRESHOLD;
    GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY    : t_alert_level                                := C_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY;
    GC_RESULT_QUEUE_COUNT_MAX                : natural                                      := C_RESULT_QUEUE_COUNT_MAX;
    GC_RESULT_QUEUE_COUNT_THRESHOLD          : natural                                      := C_RESULT_QUEUE_COUNT_THRESHOLD;
    GC_RESULT_QUEUE_COUNT_THRESHOLD_SEVERITY : t_alert_level                                := C_RESULT_QUEUE_COUNT_THRESHOLD_SEVERITY
  );
  port(
    clk                   : in    std_logic;
    axilite_vvc_master_if : inout t_axilite_if := init_axilite_if_signals(GC_ADDR_WIDTH, GC_DATA_WIDTH)
  );
begin
  -- Check the interface widths to assure that the interface was correctly set up
  assert (axilite_vvc_master_if.write_address_channel.awaddr'length = GC_ADDR_WIDTH) report "axilite_vvc_master_if.write_address_channel.awaddr'length =/ GC_ADDR_WIDTH" severity failure;
  assert (axilite_vvc_master_if.read_address_channel.araddr'length = GC_ADDR_WIDTH) report "axilite_vvc_master_if.read_address_channel.araddr'length =/ GC_ADDR_WIDTH" severity failure;
  assert (axilite_vvc_master_if.write_data_channel.wdata'length = GC_DATA_WIDTH) report "axilite_vvc_master_if.write_data_channel.wdata'length =/ GC_DATA_WIDTH" severity failure;
  assert (axilite_vvc_master_if.write_data_channel.wstrb'length = GC_DATA_WIDTH / 8) report "axilite_vvc_master_if.write_data_channel.wstrb'length =/ GC_DATA_WIDTH/8" severity failure;
  assert (axilite_vvc_master_if.read_data_channel.rdata'length = GC_DATA_WIDTH) report "axilite_vvc_master_if.read_data_channel.rdata'length =/ GC_DATA_WIDTH" severity failure;
end entity axilite_vvc;

--=================================================================================================
--=================================================================================================

architecture behave of axilite_vvc is

  constant C_SCOPE      : string       := C_VVC_NAME & "," & to_string(GC_INSTANCE_IDX);
  constant C_VVC_LABELS : t_vvc_labels := assign_vvc_labels(C_SCOPE, C_VVC_NAME, GC_INSTANCE_IDX, NA);

  signal executor_is_busy                           : boolean := false;
  signal write_address_channel_executor_is_busy     : boolean := false;
  signal write_data_channel_executor_is_busy        : boolean := false;
  signal write_response_channel_executor_is_busy    : boolean := false;
  signal read_address_channel_executor_is_busy      : boolean := false;
  signal read_data_channel_executor_is_busy         : boolean := false;
  signal any_executors_busy                         : boolean := false;
  signal queue_is_increasing                        : boolean := false;
  signal write_address_channel_queue_is_increasing  : boolean := false;
  signal write_data_channel_queue_is_increasing     : boolean := false;
  signal write_response_channel_queue_is_increasing : boolean := false;
  signal read_address_channel_queue_is_increasing   : boolean := false;
  signal read_data_channel_queue_is_increasing      : boolean := false;
  signal last_cmd_idx_executed                      : natural := natural'high;
  signal last_write_response_channel_idx_executed   : natural := 0;
  signal last_read_data_channel_idx_executed        : natural := 0;
  signal terminate_current_cmd                      : t_flag_record;

  -- Instantiation of the element dedicated Queue
  shared variable command_queue                : work.td_cmd_queue_pkg.t_generic_queue;
  shared variable write_address_channel_queue  : work.td_cmd_queue_pkg.t_generic_queue;
  shared variable write_data_channel_queue     : work.td_cmd_queue_pkg.t_generic_queue;
  shared variable write_response_channel_queue : work.td_cmd_queue_pkg.t_generic_queue;
  shared variable read_address_channel_queue   : work.td_cmd_queue_pkg.t_generic_queue;
  shared variable read_data_channel_queue      : work.td_cmd_queue_pkg.t_generic_queue;
  shared variable result_queue                 : work.td_result_queue_pkg.t_generic_queue;

  alias vvc_config                          : t_vvc_config is shared_axilite_vvc_config(GC_INSTANCE_IDX);
  alias vvc_status                          : t_vvc_status is shared_axilite_vvc_status(GC_INSTANCE_IDX);
  -- Transaction info
  alias vvc_transaction_info_trigger        : std_logic is global_axilite_vvc_transaction_trigger(GC_INSTANCE_IDX);
  alias vvc_transaction_info                : t_transaction_group is shared_axilite_vvc_transaction_info(GC_INSTANCE_IDX);
  -- VVC Activity
  signal entry_num_in_vvc_activity_register : integer;

  --UVVM: temporary fix for HVVC, remove function below in v3.0
  function get_msg_id_panel(
    constant command    : in t_vvc_cmd_record;
    constant vvc_config : in t_vvc_config
  ) return t_msg_id_panel is
  begin
    -- If the parent_msg_id_panel is set then use it,
    -- otherwise use the VVCs msg_id_panel from its config.
    if command.msg(1 to 5) = "HVVC:" then
      return vvc_config.parent_msg_id_panel;
    else
      return vvc_config.msg_id_panel;
    end if;
  end function;

  impure function queues_are_empty(
    constant void : t_void
  ) return boolean is
    variable v_return : boolean := false;
  begin
    return command_queue.is_empty(VOID) and write_address_channel_queue.is_empty(VOID) and write_data_channel_queue.is_empty(VOID) and write_response_channel_queue.is_empty(VOID) and read_address_channel_queue.is_empty(VOID) and read_data_channel_queue.is_empty(VOID);
  end function;

begin

  --===============================================================================================
  -- Constructor
  -- - Set up the defaults and show constructor if enabled
  --===============================================================================================
  work.td_vvc_entity_support_pkg.vvc_constructor(C_SCOPE, GC_INSTANCE_IDX, vvc_config, command_queue, result_queue, GC_AXILITE_CONFIG,
                                                 GC_CMD_QUEUE_COUNT_MAX, GC_CMD_QUEUE_COUNT_THRESHOLD, GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY,
                                                 GC_RESULT_QUEUE_COUNT_MAX, GC_RESULT_QUEUE_COUNT_THRESHOLD, GC_RESULT_QUEUE_COUNT_THRESHOLD_SEVERITY);
  --===============================================================================================

  --===============================================================================================
  -- Set if any of the executors are busy
  --===============================================================================================
  any_executors_busy <= executor_is_busy or write_address_channel_executor_is_busy or write_data_channel_executor_is_busy or write_response_channel_executor_is_busy or read_address_channel_executor_is_busy or read_data_channel_executor_is_busy;
  --===============================================================================================

  --===============================================================================================
  -- Command interpreter
  -- - Interpret, decode and acknowledge commands from the central sequencer
  --===============================================================================================
  cmd_interpreter : process
    variable v_cmd_has_been_acked : boolean; -- Indicates if acknowledge_cmd() has been called for the current shared_vvc_cmd
    variable v_local_vvc_cmd      : t_vvc_cmd_record := C_VVC_CMD_DEFAULT;
    variable v_msg_id_panel       : t_msg_id_panel;
    variable v_temp_msg_id_panel  : t_msg_id_panel; --UVVM: temporary fix for HVVC, remove in v3.0
  begin
    -- 0. Initialize the process prior to first command
    work.td_vvc_entity_support_pkg.initialize_interpreter(terminate_current_cmd, global_awaiting_completion);
    -- initialise shared_vvc_last_received_cmd_idx for channel and instance
    shared_vvc_last_received_cmd_idx(NA, GC_INSTANCE_IDX) := 0;
    -- Register VVC in vvc activity register
    entry_num_in_vvc_activity_register                    <= shared_vvc_activity_register.priv_register_vvc(name                     => C_VVC_NAME,
                                                                                                            instance                 => GC_INSTANCE_IDX,
                                                                                                            await_selected_supported => false);
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel                                        := vvc_config.msg_id_panel;

    -- Then for every single command from the sequencer
    loop                                -- basically as long as new commands are received

      -- 1. wait until command targeted at this VVC. Must match VVC name, instance and channel (if applicable)
      --    releases global semaphore
      -------------------------------------------------------------------------
      work.td_vvc_entity_support_pkg.await_cmd_from_sequencer(C_VVC_LABELS, vvc_config, THIS_VVCT, VVC_BROADCAST, global_vvc_busy, global_vvc_ack, v_local_vvc_cmd);
      v_cmd_has_been_acked                                  := false; -- Clear flag
      -- update shared_vvc_last_received_cmd_idx with received command index
      shared_vvc_last_received_cmd_idx(NA, GC_INSTANCE_IDX) := v_local_vvc_cmd.cmd_idx;
      -- Select between a provided msg_id_panel via the vvc_cmd_record from a VVC with a higher hierarchy or the
      -- msg_id_panel in this VVC's config. This is to correctly handle the logging when using Hierarchical-VVCs.
      v_msg_id_panel                                        := get_msg_id_panel(v_local_vvc_cmd, vvc_config);

      -- 2a. Put command on the queue if intended for the executor
      -------------------------------------------------------------------------
      if v_local_vvc_cmd.command_type = QUEUED then
        work.td_vvc_entity_support_pkg.put_command_on_queue(v_local_vvc_cmd, command_queue, vvc_status, queue_is_increasing);

      -- 2b. Otherwise command is intended for immediate response
      -------------------------------------------------------------------------
      elsif v_local_vvc_cmd.command_type = IMMEDIATE then

        --UVVM: temporary fix for HVVC, remove two lines below in v3.0
        if v_local_vvc_cmd.operation /= DISABLE_LOG_MSG and v_local_vvc_cmd.operation /= ENABLE_LOG_MSG then
          v_temp_msg_id_panel     := vvc_config.msg_id_panel;
          vvc_config.msg_id_panel := v_msg_id_panel;
        end if;

        case v_local_vvc_cmd.operation is

          when AWAIT_COMPLETION =>
            work.td_vvc_entity_support_pkg.interpreter_await_completion(v_local_vvc_cmd, command_queue, vvc_config, any_executors_busy, C_VVC_LABELS, last_cmd_idx_executed);

          when AWAIT_ANY_COMPLETION =>
            if not v_local_vvc_cmd.gen_boolean then
              -- Called with lastness = NOT_LAST: Acknowledge immediately to let the sequencer continue
              work.td_target_support_pkg.acknowledge_cmd(global_vvc_ack, v_local_vvc_cmd.cmd_idx);
              v_cmd_has_been_acked := true;
            end if;
            work.td_vvc_entity_support_pkg.interpreter_await_any_completion(v_local_vvc_cmd, command_queue, vvc_config, any_executors_busy, C_VVC_LABELS, last_cmd_idx_executed, global_awaiting_completion);

          when DISABLE_LOG_MSG =>
            uvvm_util.methods_pkg.disable_log_msg(v_local_vvc_cmd.msg_id, vvc_config.msg_id_panel, to_string(v_local_vvc_cmd.msg) & format_command_idx(v_local_vvc_cmd), C_SCOPE, v_local_vvc_cmd.quietness);

          when ENABLE_LOG_MSG =>
            uvvm_util.methods_pkg.enable_log_msg(v_local_vvc_cmd.msg_id, vvc_config.msg_id_panel, to_string(v_local_vvc_cmd.msg) & format_command_idx(v_local_vvc_cmd), C_SCOPE, v_local_vvc_cmd.quietness);

          when FLUSH_COMMAND_QUEUE =>
            work.td_vvc_entity_support_pkg.interpreter_flush_command_queue(v_local_vvc_cmd, command_queue, vvc_config, vvc_status, C_VVC_LABELS);
            work.td_vvc_entity_support_pkg.interpreter_flush_command_queue(v_local_vvc_cmd, write_address_channel_queue, vvc_config, vvc_status, C_VVC_LABELS);
            work.td_vvc_entity_support_pkg.interpreter_flush_command_queue(v_local_vvc_cmd, write_data_channel_queue, vvc_config, vvc_status, C_VVC_LABELS);
            work.td_vvc_entity_support_pkg.interpreter_flush_command_queue(v_local_vvc_cmd, write_response_channel_queue, vvc_config, vvc_status, C_VVC_LABELS);
            work.td_vvc_entity_support_pkg.interpreter_flush_command_queue(v_local_vvc_cmd, read_address_channel_queue, vvc_config, vvc_status, C_VVC_LABELS);
            work.td_vvc_entity_support_pkg.interpreter_flush_command_queue(v_local_vvc_cmd, read_data_channel_queue, vvc_config, vvc_status, C_VVC_LABELS);

          when TERMINATE_CURRENT_COMMAND =>
            work.td_vvc_entity_support_pkg.interpreter_terminate_current_command(v_local_vvc_cmd, vvc_config, C_VVC_LABELS, terminate_current_cmd);

          when FETCH_RESULT =>
            work.td_vvc_entity_support_pkg.interpreter_fetch_result(result_queue, v_local_vvc_cmd, vvc_config, C_VVC_LABELS, last_cmd_idx_executed, shared_vvc_response);

          when others =>
            tb_error("Unsupported command received for IMMEDIATE execution: '" & to_string(v_local_vvc_cmd.operation) & "'", C_SCOPE);

        end case;

        --UVVM: temporary fix for HVVC, remove line below in v3.0
        if v_local_vvc_cmd.operation /= DISABLE_LOG_MSG and v_local_vvc_cmd.operation /= ENABLE_LOG_MSG then
          vvc_config.msg_id_panel := v_temp_msg_id_panel;
        end if;

      else
        tb_error("command_type is not IMMEDIATE or QUEUED", C_SCOPE);
      end if;

      -- 3. Acknowledge command after runing or queuing the command
      -------------------------------------------------------------------------
      if not v_cmd_has_been_acked then
        work.td_target_support_pkg.acknowledge_cmd(global_vvc_ack, v_local_vvc_cmd.cmd_idx);
      end if;

    end loop;
  end process;
  --===============================================================================================

  --===============================================================================================
  -- Updating the activity register
  --===============================================================================================
  p_activity_register_update : process
    variable v_cmd_queues_are_empty : boolean;
  begin
    -- Wait until active and set the activity register to ACTIVE
    if not any_executors_busy then
      wait until any_executors_busy;
    end if;
    v_cmd_queues_are_empty := queues_are_empty(VOID);
    update_vvc_activity_register(global_trigger_vvc_activity_register, vvc_status, ACTIVE, entry_num_in_vvc_activity_register, last_cmd_idx_executed, v_cmd_queues_are_empty, C_SCOPE);
    -- Wait until inactive and set the activity register to INACTIVE
    while any_executors_busy loop
      wait until not any_executors_busy;
      wait for 0 ps;
      exit when not any_executors_busy;
    end loop;
    v_cmd_queues_are_empty := queues_are_empty(VOID);
    update_vvc_activity_register(global_trigger_vvc_activity_register, vvc_status, INACTIVE, entry_num_in_vvc_activity_register, last_cmd_idx_executed, v_cmd_queues_are_empty, C_SCOPE);
  end process p_activity_register_update;

  --===============================================================================================
  -- Command executor
  -- - Fetch and execute the commands
  --===============================================================================================
  cmd_executor : process
    variable v_cmd                                   : t_vvc_cmd_record;
    variable v_read_data                             : t_vvc_result; -- See vvc_cmd_pkg
    variable v_timestamp_start_of_current_bfm_access : time                                         := 0 ns;
    variable v_timestamp_start_of_last_bfm_access    : time                                         := 0 ns;
    variable v_timestamp_end_of_last_bfm_access      : time                                         := 0 ns;
    variable v_command_is_bfm_access                 : boolean                                      := false;
    variable v_prev_command_was_bfm_access           : boolean                                      := false;
    variable v_msg_id_panel                          : t_msg_id_panel;
    variable v_normalised_addr                       : unsigned(GC_ADDR_WIDTH - 1 downto 0)         := (others => '0');
    variable v_normalised_data                       : std_logic_vector(GC_DATA_WIDTH - 1 downto 0) := (others => '0');
    variable v_cmd_queues_are_empty                  : boolean;

  begin
    -- 0. Initialize the process prior to first command
    -------------------------------------------------------------------------
    work.td_vvc_entity_support_pkg.initialize_executor(terminate_current_cmd);
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;

    -- Setup AXILite scoreboard
    AXILITE_VVC_SB.set_scope("AXILITE_VVC_SB");
    AXILITE_VVC_SB.enable(GC_INSTANCE_IDX, "AXILITE VVC SB Enabled");
    AXILITE_VVC_SB.config(GC_INSTANCE_IDX, C_SB_CONFIG_DEFAULT);
    AXILITE_VVC_SB.enable_log_msg(GC_INSTANCE_IDX, ID_DATA);

    loop

      -- 1. Set defaults, fetch command and log
      -------------------------------------------------------------------------
      work.td_vvc_entity_support_pkg.fetch_command_and_prepare_executor(v_cmd, command_queue, vvc_config, vvc_status, queue_is_increasing, executor_is_busy, C_VVC_LABELS);

      -- Select between a provided msg_id_panel via the vvc_cmd_record from a VVC with a higher hierarchy or the
      -- msg_id_panel in this VVC's config. This is to correctly handle the logging when using Hierarchical-VVCs.
      v_msg_id_panel := get_msg_id_panel(v_cmd, vvc_config);

      -- Check if command is a BFM access
      v_prev_command_was_bfm_access := v_command_is_bfm_access; -- save for inter_bfm_delay
      if v_cmd.operation = WRITE or v_cmd.operation = READ or v_cmd.operation = CHECK then
        v_command_is_bfm_access := true;
      else
        v_command_is_bfm_access := false;
      end if;

      -- Insert delay if needed
      work.td_vvc_entity_support_pkg.insert_inter_bfm_delay_if_requested(vvc_config                         => vvc_config,
                                                                         command_is_bfm_access              => v_prev_command_was_bfm_access,
                                                                         timestamp_start_of_last_bfm_access => v_timestamp_start_of_last_bfm_access,
                                                                         timestamp_end_of_last_bfm_access   => v_timestamp_end_of_last_bfm_access,
                                                                         msg_id_panel                       => v_msg_id_panel,
                                                                         scope                              => C_SCOPE);

      if v_command_is_bfm_access then
        v_timestamp_start_of_current_bfm_access := now;
      end if;

      -- 2. Execute the fetched command
      -------------------------------------------------------------------------
      case v_cmd.operation is           -- Only operations in the dedicated record are relevant

        -- VVC dedicated operations
        --===================================
        when WRITE =>
          -- Set vvc transaction info
          set_global_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);

          -- Normalise address and data
          v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "v_cmd.addr", "v_normalised_addr", "axilite_write() called with to wide address. " & v_cmd.msg);
          v_normalised_data := normalize_and_check(v_cmd.data, v_normalised_data, ALLOW_WIDER_NARROWER, "v_cmd.data", "v_normalised_data", "axilite_write() called with to wide data. " & v_cmd.msg);

          -- Adding the write command to the write address channel queue , write data channel queue and write response channel queue
          work.td_vvc_entity_support_pkg.put_command_on_queue(v_cmd, write_address_channel_queue, vvc_status, write_address_channel_queue_is_increasing);
          work.td_vvc_entity_support_pkg.put_command_on_queue(v_cmd, write_data_channel_queue, vvc_status, write_data_channel_queue_is_increasing);
          work.td_vvc_entity_support_pkg.put_command_on_queue(v_cmd, write_response_channel_queue, vvc_status, write_response_channel_queue_is_increasing);

        when READ =>
          -- Set vvc transaction info
          set_global_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);

          -- Normalise address and data
          v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "v_cmd.addr", "v_normalised_addr", "axilite_read() called with to wide address. " & v_cmd.msg);

          -- Adding the read command to the read address channel queue and the read address data queue
          work.td_vvc_entity_support_pkg.put_command_on_queue(v_cmd, read_address_channel_queue, vvc_status, read_address_channel_queue_is_increasing);
          work.td_vvc_entity_support_pkg.put_command_on_queue(v_cmd, read_data_channel_queue, vvc_status, read_data_channel_queue_is_increasing);

        when CHECK =>
          -- Set vvc transaction info
          set_global_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);

          -- Normalise address and data
          v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "v_cmd.addr", "v_normalised_addr", "axilite_check() called with to wide address. " & v_cmd.msg);
          v_normalised_data := normalize_and_check(v_cmd.data, v_normalised_data, ALLOW_WIDER_NARROWER, "v_cmd.data", "v_normalised_data", "axilite_check() called with to wide data. " & v_cmd.msg);

          -- Adding the check command to the read address channel queue and the read address data queue
          work.td_vvc_entity_support_pkg.put_command_on_queue(v_cmd, read_address_channel_queue, vvc_status, read_address_channel_queue_is_increasing);
          work.td_vvc_entity_support_pkg.put_command_on_queue(v_cmd, read_data_channel_queue, vvc_status, read_data_channel_queue_is_increasing);

        -- UVVM common operations
        --===================================
        when INSERT_DELAY =>
          log(ID_INSERTED_DELAY, "Running: " & to_string(v_cmd.proc_call) & " " & format_command_idx(v_cmd), C_SCOPE, v_msg_id_panel);
          if v_cmd.gen_integer_array(0) = -1 then
            -- Delay specified using time
            wait until terminate_current_cmd.is_active = '1' for v_cmd.delay;
          else
            -- Delay specified using integer
            check_value(vvc_config.bfm_config.clock_period > -1 ns, TB_ERROR, "Check that clock_period is configured when using insert_delay().",
                        C_SCOPE, ID_NEVER, v_msg_id_panel);
            wait until terminate_current_cmd.is_active = '1' for v_cmd.gen_integer_array(0) * vvc_config.bfm_config.clock_period;
          end if;

        when others =>
          tb_error("Unsupported local command received for execution: '" & to_string(v_cmd.operation) & "'", C_SCOPE);
      end case;

      if v_command_is_bfm_access then
        v_timestamp_end_of_last_bfm_access   := now;
        v_timestamp_start_of_last_bfm_access := v_timestamp_start_of_current_bfm_access;
        if ((vvc_config.inter_bfm_delay.delay_type = TIME_START2START) and ((now - v_timestamp_start_of_current_bfm_access) > vvc_config.inter_bfm_delay.delay_in_time)) then
          alert(vvc_config.inter_bfm_delay.inter_bfm_delay_violation_severity, "BFM access exceeded specified start-to-start inter-bfm delay, " & to_string(vvc_config.inter_bfm_delay.delay_in_time) & ".", C_SCOPE);
        end if;
      end if;

      -- Reset terminate flag if any occurred
      if (terminate_current_cmd.is_active = '1') then
        log(ID_CMD_EXECUTOR, "Termination request received", C_SCOPE, v_msg_id_panel);
        uvvm_vvc_framework.ti_vvc_framework_support_pkg.reset_flag(terminate_current_cmd);
      end if;

      -- In case we only allow a single pending transaction, wait here until every channel is finished. 
      -- Even though this wait doesn't have a timeout, each of the executors have timeouts.
      if vvc_config.force_single_pending_transaction and v_command_is_bfm_access then
        wait until not write_address_channel_executor_is_busy and not write_data_channel_executor_is_busy and not write_response_channel_executor_is_busy and not read_address_channel_executor_is_busy and not read_data_channel_executor_is_busy;
      end if;

    end loop;
  end process;
  --===============================================================================================

  --===============================================================================================
  -- Read address channel executor
  -- - Fetch and execute the read address channel transactions
  --===============================================================================================
  read_address_channel_executor : process
    variable v_cmd                  : t_vvc_cmd_record;
    variable v_msg_id_panel         : t_msg_id_panel;
    variable v_normalised_addr      : unsigned(GC_ADDR_WIDTH - 1 downto 0) := (others => '0');
    variable v_cmd_queues_are_empty : boolean;
    constant C_CHANNEL_SCOPE        : string                               := C_VVC_NAME & "_AR" & "," & to_string(GC_INSTANCE_IDX);
    constant C_CHANNEL_VVC_LABELS   : t_vvc_labels                         := assign_vvc_labels(C_CHANNEL_SCOPE, C_VVC_NAME, GC_INSTANCE_IDX, NA);
  begin
    -- Set the command response queue up to the same settings as the command queue
    read_address_channel_queue.set_scope(C_CHANNEL_SCOPE & ":Q");
    read_address_channel_queue.set_queue_count_max(GC_CMD_QUEUE_COUNT_MAX);
    read_address_channel_queue.set_queue_count_threshold(GC_CMD_QUEUE_COUNT_THRESHOLD);
    read_address_channel_queue.set_queue_count_threshold_severity(GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY);
    -- Wait until VVC is registered in vvc activity register in the interpreter
    wait until entry_num_in_vvc_activity_register >= 0;
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;
    loop
      -- Fetch commands
      work.td_vvc_entity_support_pkg.fetch_command_and_prepare_executor(v_cmd, read_address_channel_queue, vvc_config, vvc_status, read_address_channel_queue_is_increasing, read_address_channel_executor_is_busy, C_CHANNEL_VVC_LABELS, shared_msg_id_panel, ID_CHANNEL_EXECUTOR, ID_CHANNEL_EXECUTOR_WAIT);
      -- Select between a provided msg_id_panel via the vvc_cmd_record from a VVC with a higher hierarchy or the
      -- msg_id_panel in this VVC's config. This is to correctly handle the logging when using Hierarchical-VVCs.
      v_msg_id_panel    := get_msg_id_panel(v_cmd, vvc_config);
      -- Normalise address
      v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "addr", "shared_vvc_cmd.addr", "Function called with to wide address. " & v_cmd.msg);
      -- Handling commands
      case v_cmd.operation is
        when READ | CHECK =>
          -- Set vvc transaction info
          set_arw_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);
          -- Start transaction
          read_address_channel_write(araddr_value => std_logic_vector(v_normalised_addr),
                                     msg          => format_msg(v_cmd),
                                     clk          => clk,
                                     araddr       => axilite_vvc_master_if.read_address_channel.araddr,
                                     arvalid      => axilite_vvc_master_if.read_address_channel.arvalid,
                                     arprot       => axilite_vvc_master_if.read_address_channel.arprot,
                                     arready      => axilite_vvc_master_if.read_address_channel.arready,
                                     scope        => C_CHANNEL_SCOPE,
                                     msg_id_panel => v_msg_id_panel,
                                     config       => vvc_config.bfm_config);

        when others =>
          tb_error("Unsupported local command received for execution: '" & to_string(v_cmd.operation) & "'", C_CHANNEL_SCOPE);
      end case;
      -- Set vvc transaction info back to default values
      reset_arw_vvc_transaction_info(vvc_transaction_info, v_cmd);
    end loop;
  end process;
  --===============================================================================================

  --===============================================================================================
  -- Read data channel executor
  -- - Fetch and execute the read data channel transactions
  --===============================================================================================
  read_data_channel_executor : process
    variable v_cmd                  : t_vvc_cmd_record;
    variable v_msg_id_panel         : t_msg_id_panel;
    variable v_read_data            : t_vvc_result; -- See vvc_cmd_pkg
    variable v_normalised_data      : std_logic_vector(GC_DATA_WIDTH - 1 downto 0) := (others => '0');
    variable v_cmd_queues_are_empty : boolean;
    constant C_CHANNEL_SCOPE        : string                                       := C_VVC_NAME & "_R" & "," & to_string(GC_INSTANCE_IDX);
    constant C_CHANNEL_VVC_LABELS   : t_vvc_labels                                 := assign_vvc_labels(C_CHANNEL_SCOPE, C_VVC_NAME, GC_INSTANCE_IDX, NA);
  begin
    -- Set the command response queue up to the same settings as the command queue
    read_data_channel_queue.set_scope(C_CHANNEL_SCOPE & ":Q");
    read_data_channel_queue.set_queue_count_max(GC_CMD_QUEUE_COUNT_MAX);
    read_data_channel_queue.set_queue_count_threshold(GC_CMD_QUEUE_COUNT_THRESHOLD);
    read_data_channel_queue.set_queue_count_threshold_severity(GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY);
    -- Wait until VVC is registered in vvc activity register in the interpreter
    wait until entry_num_in_vvc_activity_register >= 0;
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;
    loop
      -- Fetch commands
      work.td_vvc_entity_support_pkg.fetch_command_and_prepare_executor(v_cmd, read_data_channel_queue, vvc_config, vvc_status, read_data_channel_queue_is_increasing, read_data_channel_executor_is_busy, C_CHANNEL_VVC_LABELS, shared_msg_id_panel, ID_CHANNEL_EXECUTOR, ID_CHANNEL_EXECUTOR_WAIT);
      -- Select between a provided msg_id_panel via the vvc_cmd_record from a VVC with a higher hierarchy or the
      -- msg_id_panel in this VVC's config. This is to correctly handle the logging when using Hierarchical-VVCs.
      v_msg_id_panel    := get_msg_id_panel(v_cmd, vvc_config);
      -- Normalise data
      v_normalised_data := normalize_and_check(v_cmd.data, v_normalised_data, ALLOW_WIDER_NARROWER, "data", "shared_vvc_cmd.data", "Function called with to wide data. " & v_cmd.msg);
      -- Handling commands
      case v_cmd.operation is
        when READ =>
          -- Set vvc transaction info
          set_r_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);
          -- Start transaction
          read_data_channel_receive(rdata_value  => v_read_data(GC_DATA_WIDTH - 1 downto 0),
                                    msg          => format_msg(v_cmd),
                                    clk          => clk,
                                    rready       => axilite_vvc_master_if.read_data_channel.rready,
                                    rdata        => axilite_vvc_master_if.read_data_channel.rdata,
                                    rresp        => axilite_vvc_master_if.read_data_channel.rresp,
                                    rvalid       => axilite_vvc_master_if.read_data_channel.rvalid,
                                    scope        => C_CHANNEL_SCOPE,
                                    msg_id_panel => v_msg_id_panel,
                                    config       => vvc_config.bfm_config);
          -- Request SB check result
          if v_cmd.data_routing = TO_SB then
            -- call SB check_received
            AXILITE_VVC_SB.check_received(GC_INSTANCE_IDX, pad_axilite_sb(v_read_data(GC_DATA_WIDTH - 1 downto 0)));
          else
            -- Store the result
            work.td_vvc_entity_support_pkg.store_result(result_queue => result_queue,
                                                        cmd_idx      => v_cmd.cmd_idx,
                                                        result       => v_read_data);
          end if;

        when CHECK =>
          -- Set vvc transaction info
          set_r_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);
          -- Start transaction
          read_data_channel_check(rdata_exp    => v_normalised_data,
                                  msg          => format_msg(v_cmd),
                                  clk          => clk,
                                  rready       => axilite_vvc_master_if.read_data_channel.rready,
                                  rdata        => axilite_vvc_master_if.read_data_channel.rdata,
                                  rresp        => axilite_vvc_master_if.read_data_channel.rresp,
                                  rvalid       => axilite_vvc_master_if.read_data_channel.rvalid,
                                  alert_level  => v_cmd.alert_level,
                                  scope        => C_CHANNEL_SCOPE,
                                  msg_id_panel => v_msg_id_panel,
                                  config       => vvc_config.bfm_config);
        when others =>
          tb_error("Unsupported local command received for execution: '" & to_string(v_cmd.operation) & "'", C_CHANNEL_SCOPE);
      end case;
      last_read_data_channel_idx_executed <= v_cmd.cmd_idx;
      -- Set vvc transaction info back to default values
      reset_r_vvc_transaction_info(vvc_transaction_info);
      reset_vvc_transaction_info(vvc_transaction_info, v_cmd);
    end loop;
  end process;
  --===============================================================================================

  --===============================================================================================
  -- write address channel executor
  -- - Fetch and execute the write address channel transactions
  --===============================================================================================
  write_address_channel_executor : process
    variable v_cmd                  : t_vvc_cmd_record;
    variable v_msg_id_panel         : t_msg_id_panel;
    variable v_normalised_addr      : unsigned(GC_ADDR_WIDTH - 1 downto 0) := (others => '0');
    variable v_cmd_queues_are_empty : boolean;
    constant C_CHANNEL_SCOPE        : string                               := C_VVC_NAME & "_AW" & "," & to_string(GC_INSTANCE_IDX);
    constant C_CHANNEL_VVC_LABELS   : t_vvc_labels                         := assign_vvc_labels(C_CHANNEL_SCOPE, C_VVC_NAME, GC_INSTANCE_IDX, NA);
  begin
    -- Set the command response queue up to the same settings as the command queue
    write_address_channel_queue.set_scope(C_CHANNEL_SCOPE & ":Q");
    write_address_channel_queue.set_queue_count_max(GC_CMD_QUEUE_COUNT_MAX);
    write_address_channel_queue.set_queue_count_threshold(GC_CMD_QUEUE_COUNT_THRESHOLD);
    write_address_channel_queue.set_queue_count_threshold_severity(GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY);
    -- Wait until VVC is registered in vvc activity register in the interpreter
    wait until entry_num_in_vvc_activity_register >= 0;
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;
    loop
      -- Fetch commands
      work.td_vvc_entity_support_pkg.fetch_command_and_prepare_executor(v_cmd, write_address_channel_queue, vvc_config, vvc_status, write_address_channel_queue_is_increasing, write_address_channel_executor_is_busy, C_CHANNEL_VVC_LABELS, shared_msg_id_panel, ID_CHANNEL_EXECUTOR, ID_CHANNEL_EXECUTOR_WAIT);
      -- Select between a provided msg_id_panel via the vvc_cmd_record from a VVC with a higher hierarchy or the
      -- msg_id_panel in this VVC's config. This is to correctly handle the logging when using Hierarchical-VVCs.
      v_msg_id_panel    := get_msg_id_panel(v_cmd, vvc_config);
      -- Normalise address
      v_normalised_addr := normalize_and_check(v_cmd.addr, v_normalised_addr, ALLOW_WIDER_NARROWER, "addr", "shared_vvc_cmd.addr", "Function called with to wide address. " & v_cmd.msg);
      -- Set vvc transaction info
      set_arw_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);
      -- Start transaction
      write_address_channel_write(awaddr_value => std_logic_vector(v_normalised_addr),
                                  msg          => format_msg(v_cmd),
                                  clk          => clk,
                                  awaddr       => axilite_vvc_master_if.write_address_channel.awaddr,
                                  awvalid      => axilite_vvc_master_if.write_address_channel.awvalid,
                                  awprot       => axilite_vvc_master_if.write_address_channel.awprot,
                                  awready      => axilite_vvc_master_if.write_address_channel.awready,
                                  scope        => C_CHANNEL_SCOPE,
                                  msg_id_panel => v_msg_id_panel,
                                  config       => vvc_config.bfm_config);

      -- Set vvc transaction info back to default values
      reset_arw_vvc_transaction_info(vvc_transaction_info, v_cmd);
    end loop;
  end process;
  --===============================================================================================

  --===============================================================================================
  -- write data channel executor
  -- - Fetch and execute the write data channel transactions
  --===============================================================================================
  write_data_channel_executor : process
    variable v_cmd                  : t_vvc_cmd_record;
    variable v_msg_id_panel         : t_msg_id_panel;
    variable v_normalised_data      : std_logic_vector(GC_DATA_WIDTH - 1 downto 0) := (others => '0');
    variable v_cmd_queues_are_empty : boolean;
    constant C_CHANNEL_SCOPE        : string                                       := C_VVC_NAME & "_W" & "," & to_string(GC_INSTANCE_IDX);
    constant C_CHANNEL_VVC_LABELS   : t_vvc_labels                                 := assign_vvc_labels(C_CHANNEL_SCOPE, C_VVC_NAME, GC_INSTANCE_IDX, NA);
  begin
    -- Set the command response queue up to the same settings as the command queue
    write_data_channel_queue.set_scope(C_CHANNEL_SCOPE & ":Q");
    write_data_channel_queue.set_queue_count_max(GC_CMD_QUEUE_COUNT_MAX);
    write_data_channel_queue.set_queue_count_threshold(GC_CMD_QUEUE_COUNT_THRESHOLD);
    write_data_channel_queue.set_queue_count_threshold_severity(GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY);
    -- Wait until VVC is registered in vvc activity register in the interpreter
    wait until entry_num_in_vvc_activity_register >= 0;
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;
    loop
      -- Fetch commands
      work.td_vvc_entity_support_pkg.fetch_command_and_prepare_executor(v_cmd, write_data_channel_queue, vvc_config, vvc_status, write_data_channel_queue_is_increasing, write_data_channel_executor_is_busy, C_CHANNEL_VVC_LABELS, shared_msg_id_panel, ID_CHANNEL_EXECUTOR, ID_CHANNEL_EXECUTOR_WAIT);
      -- Select between a provided msg_id_panel via the vvc_cmd_record from a VVC with a higher hierarchy or the
      -- msg_id_panel in this VVC's config. This is to correctly handle the logging when using Hierarchical-VVCs.
      v_msg_id_panel    := get_msg_id_panel(v_cmd, vvc_config);
      -- Normalise data
      v_normalised_data := normalize_and_check(v_cmd.data, v_normalised_data, ALLOW_WIDER_NARROWER, "data", "shared_vvc_cmd.data", "Function called with to wide data. " & v_cmd.msg);
      -- Set vvc transaction info
      set_w_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);
      -- Start transaction
      write_data_channel_write(wdata_value  => v_normalised_data,
                               wstrb_value  => v_cmd.byte_enable((GC_DATA_WIDTH / 8 - 1) downto 0),
                               msg          => format_msg(v_cmd),
                               clk          => clk,
                               wdata        => axilite_vvc_master_if.write_data_channel.wdata,
                               wstrb        => axilite_vvc_master_if.write_data_channel.wstrb,
                               wvalid       => axilite_vvc_master_if.write_data_channel.wvalid,
                               wready       => axilite_vvc_master_if.write_data_channel.wready,
                               scope        => C_CHANNEL_SCOPE,
                               msg_id_panel => v_msg_id_panel,
                               config       => vvc_config.bfm_config);

      -- Set vvc transaction info back to default values
      reset_w_vvc_transaction_info(vvc_transaction_info);
    end loop;
  end process;
  --===============================================================================================

  --===============================================================================================
  -- write response channel executor
  -- - Fetch and execute the write response channel transactions
  --===============================================================================================
  write_response_channel_executor : process
    variable v_cmd                  : t_vvc_cmd_record;
    variable v_msg_id_panel         : t_msg_id_panel;
    variable v_normalised_data      : std_logic_vector(GC_DATA_WIDTH - 1 downto 0) := (others => '0');
    variable v_cmd_queues_are_empty : boolean;
    constant C_CHANNEL_SCOPE        : string                                       := C_VVC_NAME & "_B" & "," & to_string(GC_INSTANCE_IDX);
    constant C_CHANNEL_VVC_LABELS   : t_vvc_labels                                 := assign_vvc_labels(C_CHANNEL_SCOPE, C_VVC_NAME, GC_INSTANCE_IDX, NA);
  begin
    -- Set the command response queue up to the same settings as the command queue
    write_response_channel_queue.set_scope(C_CHANNEL_SCOPE & ":Q");
    write_response_channel_queue.set_queue_count_max(GC_CMD_QUEUE_COUNT_MAX);
    write_response_channel_queue.set_queue_count_threshold(GC_CMD_QUEUE_COUNT_THRESHOLD);
    write_response_channel_queue.set_queue_count_threshold_severity(GC_CMD_QUEUE_COUNT_THRESHOLD_SEVERITY);
    -- Wait until VVC is registered in vvc activity register in the interpreter
    wait until entry_num_in_vvc_activity_register >= 0;
    -- Set initial value of v_msg_id_panel to msg_id_panel in config
    v_msg_id_panel := vvc_config.msg_id_panel;
    loop
      -- Fetch commands
      work.td_vvc_entity_support_pkg.fetch_command_and_prepare_executor(v_cmd, write_response_channel_queue, vvc_config, vvc_status, write_response_channel_queue_is_increasing, write_response_channel_executor_is_busy, C_CHANNEL_VVC_LABELS, shared_msg_id_panel, ID_CHANNEL_EXECUTOR, ID_CHANNEL_EXECUTOR_WAIT);
      -- Select between a provided msg_id_panel via the vvc_cmd_record from a VVC with a higher hierarchy or the
      -- msg_id_panel in this VVC's config. This is to correctly handle the logging when using Hierarchical-VVCs.
      v_msg_id_panel := get_msg_id_panel(v_cmd, vvc_config);
      -- Set vvc transaction info
      set_b_vvc_transaction_info(vvc_transaction_info_trigger, vvc_transaction_info, v_cmd, vvc_config);
      -- Receiving a write response
      write_response_channel_check(msg          => format_msg(v_cmd),
                                   clk          => clk,
                                   bready       => axilite_vvc_master_if.write_response_channel.bready,
                                   bresp        => axilite_vvc_master_if.write_response_channel.bresp,
                                   bvalid       => axilite_vvc_master_if.write_response_channel.bvalid,
                                   alert_level  => error,
                                   scope        => C_CHANNEL_SCOPE,
                                   msg_id_panel => v_msg_id_panel,
                                   config       => vvc_config.bfm_config);

      last_write_response_channel_idx_executed <= v_cmd.cmd_idx;
      -- Set vvc transaction info back to default values
      reset_b_vvc_transaction_info(vvc_transaction_info);
      reset_vvc_transaction_info(vvc_transaction_info, v_cmd);
    end loop;
  end process;
  --===============================================================================================

  --===============================================================================================
  -- Command termination handler
  -- - Handles the termination request record (sets and resets terminate flag on request)
  --===============================================================================================
  cmd_terminator : uvvm_vvc_framework.ti_vvc_framework_support_pkg.flag_handler(terminate_current_cmd); -- flag: is_active, set, reset
  --===============================================================================================

end behave;
