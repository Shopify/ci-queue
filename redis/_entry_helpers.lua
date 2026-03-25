local function test_id_from_entry(value)
  if string.sub(value, 1, 1) == '{' then
    local decoded = cjson.decode(value)
    return decoded['test_id']
  end
  return value
end
