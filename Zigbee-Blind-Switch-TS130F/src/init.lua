-- Copyright 2021 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-------- Author NonAlex (Jan 2022) based on Xiaomi blind driver by veonua

local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local constants = require "st.zigbee.constants"
local defaults = require "st.zigbee.defaults"
local windowShadePreset_defaults = require "st.zigbee.defaults.windowShadePreset_defaults"
local log = require "log"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"
local mgmt_bind_resp = require "st.zigbee.zdo.mgmt_bind_response"
local mgmt_bind_req = require "st.zigbee.zdo.mgmt_bind_request"

local CLUSTER   = data_types.ClusterId(0x102)
local ATTRIBUTE = data_types.AttributeId(0x0005)

-- see https://raw.githubusercontent.com/markus-li/Hubitat/release/drivers/expanded/zigbee-aqara-smart-curtain-motor-expanded.groovy
-- for referance

local function zdo_binding_table_handler(driver, device, zb_rx)
  for _, binding_table in pairs(zb_rx.body.zdo_body.binding_table_entries) do
    log.info("binding_table: %s", binding_table)
    --if binding_table.dest_addr_mode.value == binding_table.DEST_ADDR_MODE_SHORT then
      -- send add hub to zigbee group command
    --  driver:add_hub_to_zigbee_group(binding_table.dest_addr.value)
    --end
  end
end

local function added_handler(self, device)
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({ value = { "open", "close", "pause"} }))
  device:refresh()
end

local level_handler = function(self, device, value, zb_rx)
  local body_length = zb_rx.body_length.value
  local val = math.floor(value.value)
  local state = ""

  if body_length == 0x11 then
    if val == 0 then
      device:send(cluster_base.read_attribute(device, CLUSTER, ATTRIBUTE))
    else
      log.info("moving")
    end
  else
    if val <= 3 then
      state = "closed"
      val = 0
    elseif val >= 97 then
      state = "open"
      val = 100
    else
      state = "partially open"
    end
    device:emit_event(capabilities.windowShadeLevel.shadeLevel({ value = val }))
    device:set_field("shadeLevel", val)
  end

  if state ~= "" then
    device:emit_event(capabilities.windowShade.windowShade(state))
  end
end

function pause(driver, device, command)
  device:send_to_component(command.component, zcl_clusters.WindowCovering.server.commands.Stop(device))
end

function set_window_shade_level(driver, device, number)
  local prev_level = device:get_field("shadeLevel") or 0


  if prev_level == number then
    log.info("window shade level is already set to ", number)
  return end

  local sign = 0
  local mantissa, exponent = math.frexp(number)
  mantissa = mantissa * 2 - 1
  exponent = exponent - 1
  log.info("window shade level will be set to", number)
  --local data = data_types.SinglePrecisionFloat(sign, exponent, mantissa)
  local data = data_types.Uint8(number)
  --device:send(cluster_base.write_attribute(device, CLUSTER, ATTRIBUTE, data))
  device:send(zcl_clusters.WindowCovering.server.commands.GoToLiftPercentage(device,data))

  device:emit_event(capabilities.windowShade.windowShade((number < prev_level) and "closing" or "opening"))
end

function window_shade_level_cmd(driver, device, command)
  local number = command.args.shadeLevel
  set_window_shade_level(driver, device, number)
end

function preset(driver, device, command)
  local level = device.preferences.presetPosition or device:get_field(windowShadePreset_defaults.PRESET_LEVEL_KEY) or windowShadePreset_defaults.PRESET_LEVEL

  set_window_shade_level(driver, device, level)
end


local function build_window_shade_level(value)
  return function(driver, device, command)
    set_window_shade_level(driver, device, value)
  end
end

local do_refresh = function(self, device)
  device:send( cluster_base.read_attribute(device, CLUSTER, ATTRIBUTE) )
end

local function info_changed(driver, device, event, args)
  log.info(tostring(event))
  for id, value in pairs(device.preferences) do
    if args.old_st_store.preferences[id] ~= value then
      local data = device.preferences[id]
      local attr
      local val
      if id == "reverse" then
        attr = 0xF002
        local data_msg = data_types.Enum8 (tonumber(data))
        device:send(cluster_base.write_attribute(device, data_types.ClusterId(zcl_clusters.WindowCovering.ID), attr, data_msg))
      elseif id == "lightLevel" then
        attr = 0x8001
        local data_msg = data_types.Enum8 (tonumber(data))
        device:send(cluster_base.write_attribute(device, data_types.ClusterId(zcl_clusters.OnOff.ID), attr, data_msg))
      elseif id == "calibration" then
        attr = 0xF001
        local data_msg = data_types.Enum8 (tonumber(data))
        device:send(cluster_base.write_attribute(device, data_types.ClusterId(zcl_clusters.WindowCovering.ID), attr, data_msg))
      end
      -- device:send(cluster_base.write_manufacturer_specific_attribute(device, zcl_clusters.basic_id, attr, 0x115F, data_types.Boolean, false) )
    end
  end
end

local blinds_driver_template = {
  supported_capabilities = {
    capabilities.windowShadeLevel,
    capabilities.windowShadePreset,
    capabilities.refresh,
  },
  lifecycle_handlers = {
    added = added_handler,
    infoChanged = info_changed,
  },
  cluster_configurations = {
    [capabilities.windowShadeLevel.ID] = { -- have no idea if it works
      {
        cluster = 0x102,
        attribute = 0x0008,
        minimum_interval = 1,
        maximum_interval = 600,
        data_type = data_types.Uint8,
        reportable_change = 10
      }
    }
  },
  zigbee_handlers = {
    global = {},
    cluster = {},
    zdo = {
      [mgmt_bind_resp.MGMT_BIND_RESPONSE] = zdo_binding_table_handler
    },
    attr = {
      [0x102] = {
        [0x0008] = level_handler,
      }
    }
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.close.NAME] = build_window_shade_level(0),
      [capabilities.windowShade.commands.pause.NAME] = pause,
      [capabilities.windowShade.commands.open.NAME]  = build_window_shade_level(100),
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_cmd
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = preset
    }
  },
  sub_drivers = {},
}

defaults.register_for_default_handlers(blinds_driver_template, blinds_driver_template.supported_capabilities)
local blinds = ZigbeeDriver("blinds", blinds_driver_template)
blinds:run()
