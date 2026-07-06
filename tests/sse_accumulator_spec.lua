local helpers = require 'tests.helpers'

local function get_text_fn(json)
    return json.choices[1].delta.content
end

return {
    {
        name = 'sse accumulator decodes complete lines across chunk boundaries',
        run = function()
            helpers.ensure_runtime()
            local utils = require 'minuet.utils'
            local feed = utils.make_sse_accumulator(get_text_fn)

            -- a chunk ending mid-line yields nothing yet
            helpers.expect_equal(feed 'data: {"choices":[{"delta":{"content":"fo', nil)
            -- completing the line (plus a partial next line) yields the text so far
            helpers.expect_equal(feed 'o"}}]}\ndata: {"choices":[{"delta":{"con', 'foo')
            -- completing the buffered second line appends to the accumulation
            helpers.expect_equal(feed 'tent":"\\nbar"}}]}\n', 'foo\nbar')
            -- [DONE] and blank keep-alive lines are skipped without error
            helpers.expect_equal(feed 'data: [DONE]\n\n', nil)
        end,
    },
    {
        name = 'sse accumulator reports growth only on content-bearing events',
        run = function()
            helpers.ensure_runtime()
            local utils = require 'minuet.utils'
            local feed = utils.make_sse_accumulator(get_text_fn)

            helpers.expect_equal(feed 'data: {"choices":[{"delta":{"role":"assistant"}}]}\n', nil)
            helpers.expect_equal(feed 'data: {"choices":[{"delta":{"content":"x"}}]}\n', 'x')
            helpers.expect_equal(feed 'data: {"choices":[{"delta":{"content":""}}]}\n', nil)
        end,
    },
}
