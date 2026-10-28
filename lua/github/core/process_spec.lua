describe("process execution", function()
  it("preserves stdin and calls back once on the main loop", function()
    local process = require("github.core.process")
    local result, count = nil, 0
    process.run({ "cat" }, { stdin = '日本語\n"quoted"' }, function(value)
      count = count + 1
      result = value
      assert.equals(false, vim.in_fast_event())
    end)
    assert.equals(
      true,
      vim.wait(2000, function()
        return result ~= nil
      end)
    )
    assert.same({ code = 0, signal = 0, stdout = '日本語\n"quoted"', stderr = "" }, result)
    assert.equals(1, count)
  end)
  it("reports a missing executable exactly once", function()
    local process = require("github.core.process")
    local message, count
    count = 0
    process.run({ "github-nvim-nonexistent-executable" }, {}, function(result, err)
      count = count + 1
      assert.is_nil(result)
      message = err
    end)
    assert.equals(
      true,
      vim.wait(2000, function()
        return message ~= nil
      end)
    )
    assert.equals("process failed to start", message)
    assert.equals(1, count)
  end)
end)
