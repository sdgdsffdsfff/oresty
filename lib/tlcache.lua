--
-- tjx@20190926
--

local mlcache = require 'resty.mlcache'
-- local mongo = require 'lib.mongo_client'
local lup = require 'lib.lup'
local redis_client = require 'lib.redis_client'

local _M = {}

local function cache_by_redis(red, name, key, ttl, callback, ...)
    key = name..'-'..key
    local val, err = red:get(key)
    if val and val ~= ngx.null then
        return lup.json_decode(val)[1]
    else
        val = callback(...)
        if not val then
            return nil
        end
        if not err then
            local ok, errmsg = red:set(key, lup.json_encode({val}))
            if ok then
                -- ngx.log(ngx.ERR, 'UPDATE_REDIS_SUCC_', val_to_save)
                if ttl then
                    red:expire(key, ttl)
                end
            else
                ngx.log(ngx.ERR, 'UPDATE_REDIS_ERR_', errmsg)
            end
        end
    end
    return val
end

local function cache_by_mongo(coll, name, key, ttl, callback, ...)
    --
    -- 增加一个0-4秒的随机秒数，以防并发更新缓存
    --
    local doc = coll:find_one({
        name = name, 
        key = key, 
        timestamp = {
            ['$gt'] = ngx.time() - ttl - (math.floor(lup.rand()) % 5)
        }
    }, {
        name = 0,
        key = 0,
        timestamp = 0,
    })

    local val = nil
    if doc then
        val = doc.val
    else
        val = callback(...)
        local ret, err = coll:find_and_modify({
            name = name,
            key = key,
        }, {
            update = {
                name = name,
                key = key,
                val = val,
                timestamp = ngx.time(),
            },
            upsert = true
        })
        if ret then
            ngx.log(ngx.ERR, 'UPDATE_MONGO_SUCC_'..lup.json_encode(val))
        else
            ngx.log(ngx.ERR, 'UPDATE_MONGO_ERR_'..err)
        end
    end
    return val
end

function _M.get(self, key, opts, callback, ...)
    opts = opts or {}
    local name = self.name
    local ttl_l3 = opts.ttl_l3 or self.opts.ttl_l3 or 10
    ngx.update_time()
    if self.coll then
        return self.mlc:get(key, opts, cache_by_mongo, self.coll, name, key, ttl_l3, callback, ...)
    elseif self.red then
        return self.mlc:get(key, opts, cache_by_redis, self.red, name, key, ttl_l3, callback, ...)
    end
end

function _M.new(name, shared_name, opts)
    assert(type(shared_name) == 'string', 'SHARED_NAME_ERROR')
    assert(type(opts) == 'table', 'OPTS_ERROR')

    --
    -- 初始化句柄
    --
    local mlc, coll, red = assert(mlcache.new(name, shared_name, opts))
    if opts.mongo_config then
        coll = mongo.new(shared_name, opts.mongo_config)
        coll:ensure_index({{unique = true, key = {key = 1, name = 1}}, {key = {timestamp = 1}}})
    elseif opts.redis_config then
        red = redis_client.new(opts.redis_config)
    else
        return mlc
    end

    return setmetatable({
        name = name,
        shared_name = shared_name,
        opts = opts,
        mlc = mlc,
        coll = coll,
        red = red,
    }, {__index = _M})

end

return _M
