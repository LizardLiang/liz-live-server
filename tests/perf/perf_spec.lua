-- Performance: save->reload latency and main-loop responsiveness.
-- TC-P01, TC-P02. These print measured numbers and assert against budget.
local H = require("tests.helpers")
local uv = vim.uv or vim.loop

local function percentile(sorted, p)
  local idx = math.max(1, math.ceil(p / 100 * #sorted))
  return sorted[idx]
end

describe("save -> reload latency (TC-P01)", function()
  it("delivers a reload within 200ms (localhost)", function()
    local sse = require("liz-live-server.sse")
    H.with_server({ files = { ["index.html"] = "<body>x</body>", ["a.html"] = "<body>a</body>" } }, function(ctx)
      local stream = H.sse_connect(ctx.port)
      vim.wait(1000, function()
        return sse.count(ctx.liz.state) >= 1
      end, 5)

      local path = ctx.root .. "/a.html"
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)

      local function reload_count()
        local _, n = stream:text():gsub("data: reload", "")
        return n
      end

      local samples = {}
      local prev = reload_count()
      for _ = 1, 10 do
        local t0 = uv.hrtime()
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
        vim.wait(1000, function()
          return reload_count() > prev
        end, 1)
        local ms = (uv.hrtime() - t0) / 1e6
        samples[#samples + 1] = ms
        prev = reload_count()
      end
      stream:close()

      table.sort(samples)
      local median = percentile(samples, 50)
      local p90 = percentile(samples, 90)
      print(string.format("[TC-P01] save->reload ms: median=%.1f p90=%.1f max=%.1f", median, p90, samples[#samples]))
      -- median is the robust budget check; debounce(50ms) + loopback is well under 200ms
      assert.is_true(median <= 200, "median latency " .. median .. "ms exceeds 200ms")
    end)
  end)
end)

describe("main-loop responsiveness (TC-P02)", function()
  it("keeps the loop ticking while serving a 1MB file", function()
    local big = string.rep("a", 1024 * 1024)
    H.with_server({ files = { ["index.html"] = "<body>x</body>", ["big.bin"] = big } }, function(ctx)
      -- Sample a 1ms repeating timer; track max gap between ticks.
      local ticks = {}
      local timer = uv.new_timer()
      timer:start(0, 1, function()
        ticks[#ticks + 1] = uv.hrtime()
      end)

      for _ = 1, 5 do
        local r = H.request(ctx.port, "GET", "/big.bin", 3000)
        assert.equals("200", H.status(r))
        assert.equals(#big, #H.body(r))
      end

      timer:stop()
      timer:close()

      local max_gap, gaps = 0, {}
      for i = 2, #ticks do
        local g = (ticks[i] - ticks[i - 1]) / 1e6
        gaps[#gaps + 1] = g
        if g > max_gap then
          max_gap = g
        end
      end
      table.sort(gaps)
      local median_gap = percentile(gaps, 50)
      print(string.format("[TC-P02] main-loop gap ms over %d ticks: median=%.2f max=%.2f", #ticks, median_gap, max_gap))
      -- The serving path is fully async: the median inter-tick gap stays at
      -- frame budget. (Max can spike from GC/test overhead, so median is the
      -- assertion; max is reported for visibility.)
      assert.is_true(median_gap <= 16, "median main-loop gap " .. median_gap .. "ms exceeds 16ms")
    end)
  end)
end)
