--
-- This file is part of the Doodle3D project (http://doodle3d.com).
--
-- @copyright 2013, Doodle3D
-- @license This software is licensed under the terms of the GNU GPL v2 or later.
-- See file LICENSE.txt or visit http://www.gnu.org/licenses/gpl.html for full license details.

-- TODO: return errors like in print_POST (error message in a 'msg' key instead of directly in the response) if this does not break API compatibility

local lfs = require('lfs')
local log = require('util.logger')
local utils = require('util.utils')
local settings = require('util.settings')
local printerUtils = require('util.printer')
local accessManager = require('util.access')

local MOD_ABBR = "APRN"

local M = {
	isApi = true
}


function M._global(request, response)
	-- TODO: list all printers (based on /dev/ttyACM* and /dev/ttyUSB*)
	response:setSuccess()
end

function M.temperature(request, response)
	local argId = request:get("id")
	local printer,msg = printerUtils.createPrinterOrFail(argId, response)
	if not printer or not printer:hasSocket() then return end

	local temperatures,msg = printer:getTemperatures()

	response:addData('id', argId)
	if temperatures then
		response:setSuccess()
		response:addData('hotend', temperatures.hotend)
		response:addData('hotend_target', temperatures.hotend_target)
		response:addData('bed', temperatures.bed)
		response:addData('bed_target', temperatures.bed_target)
	elseif temperatures == false then
		response:addData('status', msg)
		response:setFail("could not get temperature information (" .. msg .. ")")
	else
		response:setError(msg)
	end
end

function M.progress(request, response)
	local argId = request:get("id")
	local printer,msg = printerUtils.createPrinterOrFail(argId, response)
	if not printer or not printer:hasSocket() then return end

	-- NOTE: despite their names, `currentLine` is still the error indicator and `bufferedLines` the message in such case.
	local currentLine,bufferedLines,totalLines,bufferSize,maxBufferSize = printer:getProgress()

	response:addData('id', argId)
	if currentLine then
		response:setSuccess()
		response:addData('current_line', currentLine)
		response:addData('buffered_lines', bufferedLines)
		response:addData('total_lines', totalLines)
		response:addData('buffer_size', bufferSize)
		response:addData('max_buffer_size', maxBufferSize)
	elseif progress == false then
		response:addData('status', bufferedLines)
		response:setFail("could not get progress information (" .. bufferedLines .. ")")
	else
		response:setError(bufferedLines)
	end
end

-- Note: onlyReturnState is optional and prevents response from being modified, used when calling from within other api call
-- Note: unlike regular API-functions, this one returns either true+state or false
function M.state(request, response, onlyReturnState)
	local argId = request:get("id")
	if not onlyReturnState then response:addData('id', argId) end

	local printer,msg = printerUtils.createPrinterOrFail(argId, response)
	if not printer then
		local printerState = "disconnected"
		if not onlyReturnState then
			response:setSuccess()
			response:addData('state', printerState)
		end
		return true, printerState
	elseif not printer:hasSocket() then
		-- while dev is present but no server is running yet, return 'fake' connecting state
		local printerState = "connecting"
		if not onlyReturnState then
			response:setSuccess()
			response:addData('state', printerState)
		end
		return true, printerState
	else
		local rv,msg = printer:getState()
		if rv then
			if not onlyReturnState then
				response:setSuccess()
				response:addData('state', rv)
			end
			return true, rv
		else -- Note: do not differentiate between false and nil here, false should never be returned
			if not onlyReturnState then response:setError(msg) end
			return false
		end
	end

	--this point cannot be reached, no return necessary
end

-- retrieve a list of 3D printers currently supported
function M.listall(request, response)
	response:setSuccess()
	response:addData('printers', printerUtils.supportedPrinters())
end



function M.heatup_POST(request, response)
	if not accessManager.hasControl(request.remoteAddress) then
		response:setFail("No control access")
		return
	end

	local argId = request:get("id")
	local printer,msg = printerUtils.createPrinterOrFail(argId, response)
	if not printer or not printer:hasSocket() then return false end

	local temperature = settings.get('printer.heatup.temperature')
	local rv,msg = printer:heatup(temperature)

	response:addData('id', argId)
	if rv then
		response:setSuccess()
	elseif rv == false then
		response:addData('status', msg)
		response:setFail("could not start heatup (" .. msg .. ")")
	else
		response:setError(msg)
	end
end

function M.stop_POST(request, response)
	if not accessManager.hasControl(request.remoteAddress) then
		response:setFail("No control access")
		return
	end

	local argId = request:get("id")
	local argGcode = request:get("gcode")
	local printer,msg = printerUtils.createPrinterOrFail(argId, response)
	if not printer or not printer:hasSocket() then return end

	if(argGcode == nil) then
		argGcode = ""
	end
	local rv,msg = printer:stopPrint(argGcode)

	response:addData('id', argId)
	if rv then
		response:setSuccess()
	elseif rv == false then
		response:addData('status', msg)
		response:setFail("could not stop print (" .. msg .. ")")
	else
		response:setError(msg)
	end
end

--requires: gcode(string) (the gcode to be appended)
--accepts: id(string) (the printer ID to append to)
--accepts: clear(bool) (chunks will be concatenated but output file will be cleared first if this argument is true)
--accepts: first(deprecated) (an alias for 'clear')
--accepts: start(bool) (only when this argument is true will printing be started)
--accepts: total_lines(int) (the total number of lines that is going to be sent, will be used only for reporting progress)
--accepts: seq_number(int) (sequence number of the chunk, must be given until clear() after given once, and incremented each time)
--accepts: seq_total(int) (total number of gcode chunks to be appended, must be given until clear() after given once, and stay the same)
--returns: when the gcode buffer cannot accept the gcode, or the IPC transaction fails, a fail with a (formal, i.e., parseable) status argument will be returned
function M.print_POST(request, response)
	local controllerIP = accessManager.getController()
	local hasControl = false
	if controllerIP == "" then
		accessManager.setController(request.remoteAddress)
		hasControl = true
	elseif controllerIP == request.remoteAddress then
		hasControl = true
	end

	if not hasControl then
		response:setFail("No control access")
		return
	end

	local argId = request:get("id")
	local argGcode = request:get("gcode")
	local argClear = utils.toboolean(request:get("clear"))
	local argIsFirst = utils.toboolean(request:get("first"))  -- deprecated
	local argStart = utils.toboolean(request:get("start"))
	local argTotalLines = request:get("total_lines") or -1
	local argSeqNumber = request:get("seq_number") or -1
	local argSeqTotal = request:get("seq_total") or -1
	local remoteHost = request:getRemoteHost()
	
	log:info(MOD_ABBR, "print chunk metadata: total_lines=" .. argTotalLines .. ", seq_number=" .. argSeqNumber .. ", seq_total=" .. argSeqTotal)

	local printer,msg = printerUtils.createPrinterOrFail(argId, response)
	if not printer or not printer:hasSocket() then return end

	response:addData('id', argId)

	if argGcode == nil or argGcode == '' then
		response:setError("missing gcode argument")
		return
	end

	if argClear == true or argIsFirst == true then
		log:verbose(MOD_ABBR, "  clearing all gcode for " .. printer:getId())
		response:addData('gcode_clear',true)
		local rv,msg = printer:clearGcode()

		if rv == false then
			response:addData('status', msg)
			response:setFail("could not clear gcode (" .. msg .. ")")
		elseif rv == nil then
			response:setError(msg)
			return
		end
	end

	local rv,msg

	rv,msg = printer:appendGcode(argGcode, argTotalLines, { seq_number = argSeqNumber, seq_total = argSeqTotal, source = remoteHost })
	if rv then
		--NOTE: this does not report the number of lines, but only the block which has just been added
		response:addData('gcode_append',argGcode:len())
	elseif rv == false then
		response:addData('status', msg)
		response:setFail("could not add gcode (" .. msg .. ")")
		return
	else
		response:addData('msg', msg)
		response:setError("could not add gcode (" .. msg .. ")")
		return
	end

	if argStart == true then
		rv,msg = printer:startPrint()

		if rv then
			response:setSuccess()
			response:addData('gcode_print',true)
		elseif rv == false then
			response:addData('status', msg)
			response:setFail("could not send gcode (" .. msg .. ")")
			return
		else
			response:addData('msg', msg)
			response:setError("could not send gcode (" .. msg .. ")")
			return
		end
	else
		response:setSuccess()
	end
end

return M
