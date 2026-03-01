local function test_id_from_entry(value, delimiter)
  if delimiter then
    local pos = string.find(value, delimiter, 1, true)
    if pos then
      return string.sub(value, 1, pos - 1)
    end
  end
  return value
end
