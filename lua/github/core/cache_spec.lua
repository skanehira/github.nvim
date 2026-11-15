describe("cache", function()
  local cache = require("github.core.cache")
  before_each(function()
    cache.clear()
  end)
  it("caches successful loads", function()
    local loads = 0
    local function loader(done)
      loads = loads + 1
      done("value")
    end
    local first, second
    cache.fetch("key", 60000, loader, function(value)
      first = value
    end)
    cache.fetch("key", 60000, loader, function(value)
      second = value
    end)
    assert.equals(1, loads)
    assert.equals("value", first)
    assert.equals("value", second)
    assert.equals("value", cache.get("key"))
  end)
  it("shares one load between concurrent callers", function()
    local loads, pending = 0, {}
    local function loader(done)
      loads = loads + 1
      pending[#pending + 1] = done
    end
    local values = {}
    cache.fetch("key", 60000, loader, function(value)
      values[#values + 1] = value
    end)
    cache.fetch("key", 60000, loader, function(value)
      values[#values + 1] = value
    end)
    assert.equals(1, loads)
    assert.same({}, values)
    pending[1]("shared")
    assert.equals(1, loads)
    assert.same({ "shared", "shared" }, values)
  end)
  it("does not cache failures", function()
    local loads = 0
    local function loader(done)
      loads = loads + 1
      done(nil, "boom")
    end
    local errors = {}
    cache.fetch("key", 60000, loader, function(_, err)
      errors[#errors + 1] = err
    end)
    cache.fetch("key", 60000, loader, function(_, err)
      errors[#errors + 1] = err
    end)
    assert.equals(2, loads)
    assert.same({ "boom", "boom" }, errors)
    assert.is_nil(cache.get("key"))
  end)
  it("invalidates entries", function()
    cache.set("key", "value", 60000)
    assert.equals("value", cache.get("key"))
    cache.invalidate("key")
    assert.is_nil(cache.get("key"))
  end)
  it("expires entries after the ttl", function()
    cache.set("key", "value", 5)
    assert.equals("value", cache.get("key"))
    vim.wait(20)
    assert.is_nil(cache.get("key"))
  end)
end)
