return {
    PIECE_ASSET_BY_SYMBOL = {
        -- pawns
        P = "rbxassetid://12414175509",
        p = "rbxassetid://12446604722",
        -- rooks
        R = "rbxassetid://12414179583",
        r = "rbxassetid://12446625094",
        -- knights
        N = "rbxassetid://12414177497",
        n = "rbxassetid://12446609273",
        -- bishops
        B = "rbxassetid://7079124389",
        b = "rbxassetid://9068810371",
        -- queens
        Q = "rbxassetid://12414180706",
        q = "rbxassetid://12446617367",
        -- kings
        K = "rbxassetid://12414181580",
        k = "rbxassetid://12446620898",
    },
    FILES = {"a","b","c","d","e","f","g","h"},
    STARTING_RANKS = {
        white = {
            [1] = {"R","N","B","Q","K","B","N","R"},
            [2] = {"P","P","P","P","P","P","P","P"},
        },
        black = {
            [8] = {"r","n","b","q","k","b","n","r"},
            [7] = {"p","p","p","p","p","p","p","p"},
        }
    },
    LIGHT_COLOR = Color3.fromRGB(240,217,181),  -- light square
    DARK_COLOR  = Color3.fromRGB(181,136,99),   -- dark square
    SOUNDS = {
        MOVE = "rbxassetid://98240421775374",      -- ordinary move (non-capture)
        CAPTURE = "rbxassetid://98240421775374",   -- capture sound
        CASTLE = "rbxassetid://98240421775374",    -- castle-specific sound (chess.com has one)
        PROMOTE = "rbxassetid://98240421775374",   -- promotion sound (optional)
    }
}
