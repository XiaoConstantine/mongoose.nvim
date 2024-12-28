# 🦦 mongoose.nvim

Mongoose is a Neovim plugin that helps you understand and optimize your editing patterns by tracking and analyzing your keystroke usage across different filetypes. Think of it as a fitness tracker for your Neovim usage – it observes how you work and provides insights to help you become more efficient.

## Features

Mongoose silently watches your editing patterns and provides valuable insights about your Neovim usage:

- Tracks keystroke patterns per filetype
- Measures command execution duration
- Shows your most frequently used key sequences
- Maintains statistics across sessions
- Provides real-time analytics through a floating window
- Offers AI-powered analysis of your Vim usage patterns
- Provides personalized recommendations for improvement
- Zero impact on editor performance

## Installation

### Using lazy.nvim

```lua
{
    "XiaoConstantine/mongoose.nvim",
    event = "VeryLazy",
    config = function()
        require("mongoose").setup()
        -- Optional: Add local llm for analysis
		require("mongoose").configure_llm({
			provider = "llamacpp",
		})

        -- Optional: Add a keymap to show analytics
        vim.keymap.set('n', '<leader>ma', '<cmd>Mongoose<CR>', {
            silent = true,
            desc = "Show Mongoose Analytics"
        })

		-- Optional: Add keybinding for LLM analysis
		vim.keymap.set("n", "<leader>ml", "<cmd>MongooseLLMAnalyze<cr>", {
			silent = true,
			desc = "Analyze Vim usage with LLM",
		})
    end
}
```

### Using packer.nvim

```lua
use {
    'XiaoConstantine/mongoose.nvim',
    config = function()
        require('mongoose').setup()
    end
}
```

### Manual Installation

Clone the repository into your Neovim packages directory:

```bash
git clone https://github.com/XiaoConstantine/mongoose.nvim \
    ~/.local/share/nvim/site/pack/plugins/start/mongoose.nvim
```

## Usage

Mongoose starts tracking your keystrokes automatically after setup. To view your usage analytics:

- Use the command `:Mongoose`
- Or use the default keymap `<leader>ma` (if configured)
- Run `:MongooseLLMAnalyze` to generate an AI analysis of your editing patterns
- View the analysis by pressing `l` in the Mongoose analytics window

The analytics window shows:
- Total keystrokes for the current filetype
- Most frequently used key sequences
- Average duration for each sequence

Get personalized recommendations for:
- Inefficient patterns in your workflow
- More efficient alternatives
- A structured learning plan
- Advanced Vim techniques suited to your style


## Understanding the Analytics

The analytics window provides several key metrics:

1. Total Keystrokes: The number of keystrokes recorded for the current filetype
2. Most Used Sequences: Your most common key combinations, ordered by frequency
3. Average Duration: How long it typically takes you to execute each sequence

This information can help you:
- Identify repetitive patterns that could be simplified with custom mappings
- Discover which commands you use most frequently
- Find opportunities to learn more efficient commands
- Track your progress as you learn new Neovim features

## Configuration

Mongoose works out of the box with sensible defaults, but you can customize it during setup:

```lua
require('mongoose').setup({
    -- Configuration options coming soon!
})
```

## Data Storage

Mongoose stores your usage data in:
```
~/.local/share/nvim/mongoose_analytics.json
```

The data is saved automatically and persists between Neovim sessions. The file is human-readable JSON if you want to examine or backup your usage patterns.

## How It Works

Mongoose uses Neovim's built-in key event handling to track your keystrokes efficiently. It:

1. Captures keystrokes in real-time without impacting performance
2. Groups related keystrokes into meaningful sequences
3. Maintains separate statistics for each filetype
4. Periodically saves data to preserve your usage history
5. Provides analytics through a clean, floating window interface


## License

MIT License - See LICENSE for details
