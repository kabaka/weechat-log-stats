# WeeChat IRC Log Parser

Parse WeeChat logs and generate statistics and graphs.

# Usage

weechat-log-stats is not yet a Gem (but will be soon!). For now, run it with
`ruby -Ilib ./bin/weechat-log-stats`.

## Options

    -o, --output-dir DIR             Output directory
    -t, --message-threshold N        Minimum message count for inclusion in output
    -e, --top-emoticon-count N       Number of emoticons shown in the top emoticons
    -u, --top-domain-count N         Number of domain names to show in top domains
        --top-word-length N          Minimum length for words shown in top words
    -w, --top-word-count N           Number of words shown in the top words
    -h, --help                       Show this message

# To-do

* Output Flexibility
    * Output templates.
    * Split HTML generation into a separate class/file.
    * Remote upload.
    * Network/channel index generation.
* Log Formats
    * Support alternate time formats.
    * Maybe: support entirely different log formats.

