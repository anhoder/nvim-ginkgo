local lib = require("neotest.lib")
local plenary = require("plenary.path")
local async = require("neotest.async")
local logger = require("neotest.logging")
local utils = require("nvim-ginkgo.utils")

---@class neotest.Adapter
---@field name string
local adapter = { name = "nvim-ginkgo" }

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@return string | nil @Absolute root dir of test suite
adapter.root = lib.files.match_root_pattern("go.mod", "go.sum")

---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@param rel_path string Path to directory, relative to root
---@param root string Root directory of project
---@return boolean
function adapter.filter_dir(name, rel_path, root)
	return rel_path ~= "vendor"
end

---@async
---@param file_path string
---@return boolean
function adapter.is_test_file(file_path)
	if not vim.endswith(file_path, ".go") then
		return false
	end

	local file_path_segments = vim.split(file_path, plenary.path.sep)
	local file_path_basename = file_path_segments[#file_path_segments]
	return vim.endswith(file_path_basename, "_test.go")
end

---Given a file path, parse all the tests within it.
---@async
---@param file_path string Absolute file path
---@diagnostic disable-next-line: undefined-doc-name
---@return neotest.Tree | nil
function adapter.discover_positions(file_path)
	local query = [[
    ; -- Namespaces --
    ; Matches: `Describe('subject')` and `Context('case')` and `When('case')`
    ((call_expression
      function: (identifier) @func.name (#any-of? @func.name "Describe" "Context" "When" "DescribeTable")
      arguments: (argument_list ((interpreted_string_literal) @namespace.name))
    )) @namespace.definition

    ; -- Tests --
    ; Matches: `It('test')`
    ((call_expression
      function: (identifier) @func.name (#any-of? @func.name "It" "Entry")
      arguments: (argument_list ((interpreted_string_literal) @test.name))
    )) @test.definition
  ]]

	return lib.treesitter.parse_positions(file_path, query, {
		nested_namespaces = true,
		require_namespaces = true,
		build_position = function(fpath, source, captured_nodes)
			local match_type
			if captured_nodes["test.name"] then
				match_type = "test"
			end
			if captured_nodes["namespace.name"] then
				match_type = "namespace"
			end
			if not match_type then
				return
			end

			---@type string
			local name = vim.treesitter.get_node_text(captured_nodes[match_type .. ".name"], source)
			local definition = captured_nodes[match_type .. ".definition"]

			if captured_nodes["func.name"] then
				local func_name = vim.treesitter.get_node_text(captured_nodes["func.name"], source)
				if func_name == "When" then
					name = '"when ' .. string.sub(name, string.find(name, '"') + 1)
				end
			end

			return {
				type = match_type,
				path = fpath,
				name = name,
				range = { definition:range() },
			}
		end,
	})
end

---@diagnostic disable-next-line: undefined-doc-name
---@param args neotest.RunArgs
---@diagnostic disable-next-line: undefined-doc-name
---@return nil | neotest.RunSpec | neotest.RunSpec[]
function adapter.build_spec(args)
	local report_path = async.fn.tempname()
	---@diagnostic disable-next-line: undefined-field
	local strategy = args.strategy
	local cargs = {}

	table.insert(cargs, "ginkgo")
	table.insert(cargs, "run")
	vim.list_extend(cargs, adapter._ginkgo_args)
	table.insert(cargs, "--json-report")
	table.insert(cargs, vim.fn.fnamemodify(report_path, ":t"))
	table.insert(cargs, "--output-dir")
	table.insert(cargs, vim.fn.fnamemodify(report_path, ":h"))

	-- prepare the focus
	---@diagnostic disable-next-line: undefined-field
	local position = args.tree:data()
	if position.type == "test" or position.type == "namespace" then
		-- pos.id in form "path/to/file::Describe text::test text"
		local name = string.sub(position.id, string.find(position.id, "::") + 2)
		name, _ = string.gsub(name, "::", " ")
		name, _ = string.gsub(name, '"', "")
		-- prepare the pattern
		local pattern = '"' .. name .. '"'
		-- prepare tha arguments
		table.insert(cargs, "--focus")
		table.insert(cargs, pattern)
	end

	local directory = position.path
	-- The path for the position is not a directory, ensure the directory variable refers to one
	if vim.fn.isdirectory(position.path) ~= 1 then
		table.insert(cargs, "--focus-file")
		table.insert(cargs, position.path)
		-- find the directory
		directory = vim.fn.fnamemodify(position.path, ":h")
	end

	---@diagnostic disable-next-line: undefined-field
	local extra_args = args.extra_args or {}
	-- merge the argument
	for _, value in ipairs(extra_args) do
		table.insert(cargs, value)
	end

	table.insert(cargs, directory .. plenary.path.sep .. "...")

	-- vim.notify(table.concat(cargs, " "))

	local return_result = {
		command = table.concat(cargs, " "),
		context = {
			-- input
			report_input_type = position.type,
			report_input_path = position.path,
			-- output
			report_output_path = report_path,
		},
	}

	if strategy == "dap" then
		return_result.strategy = utils.get_dap_config()
	end

	return return_result
end

---@async
---@diagnostic disable-next-line: undefined-doc-name
---@param spec neotest.RunSpec
---@diagnostic disable-next-line: undefined-doc-name
---@param result neotest.StrategyResult
---@diagnostic disable-next-line: undefined-doc-name
---@param tree neotest.Tree
---@diagnostic disable-next-line: undefined-doc-name
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
	local collection = {}
	---@diagnostic disable-next-line: undefined-field
	local report_path = spec.context.report_output_path

	local fok, report_data = pcall(lib.files.read, report_path)
	if not fok then
		logger.error("No test output file found ", report_path)
		return {}
	end

	local dok, report = pcall(vim.json.decode, report_data, { luanil = { object = true } })
	if not dok then
		logger.error("Failed to parse test output json ", report_path)
		return {}
	end

	for _, suite_item in pairs(report) do
		if suite_item.SpecReports == nil then
			local suite_item_node = {}
			-- set the node errors
			if suite_item.SuiteSucceeded then
				suite_item_node.status = "passed"
			end

			local suite_item_node_id = suite_item.SuitePath
			collection[suite_item_node_id] = suite_item_node
		end

		for _, spec_item in pairs(suite_item.SpecReports or {}) do
			if spec_item.LeafNodeType == "It" then
				local spec_item_node = {}
				-- set the node short attribute
				spec_item_node.short = "[" .. string.upper(spec_item.State) .. "]"
				spec_item_node.short = spec_item_node.short .. " " .. utils.create_spec_description(spec_item)
				-- set the node location
				spec_item_node.location = spec_item.LeafNodeLocation.LineNumber

				-- set the node output
				spec_item_node.output = async.fn.tempname()

				if spec_item.State == "pending" then
					spec_item_node.status = "skipped"
				elseif spec_item.State == "panicked" then
					spec_item_node.status = "failed"
				else
					spec_item_node.status = spec_item.State
				end

				if spec_item_node.status == "skipped" then
					goto continue
				end

				-- set the node errors
				if spec_item.Failure ~= nil then
					spec_item_node.errors = {}

					local err = utils.create_error(spec_item)
					-- add the error
					table.insert(spec_item_node.errors, err)
					if spec_item_node.output ~= nil then
						-- write the output
						local err_output = utils.create_error_output(spec_item)
						lib.files.write(spec_item_node.output, err_output)
					end
					-- set the node short attribute
					spec_item_node.short = spec_item_node.short .. ": " .. err.message
				else
					-- write the output
					local spec_output = utils.create_spec_output(spec_item)
					lib.files.write(spec_item_node.output, spec_output)
				end

				local spec_item_node_id = utils.create_location_id(spec_item)
				collection[spec_item_node_id] = spec_item_node
			end
			::continue::
		end
	end

	return collection
end

adapter._ginkgo_args = {
	"-v",
	"--keep-going",
}

adapter.setup = function(opts)
	opts = opts or {}
	if opts.ginkgo_args then
		adapter._ginkgo_args = opts.ginkgo_args
	end

	return adapter
end

--the adatper
return adapter
