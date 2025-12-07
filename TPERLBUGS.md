# Template::EmbeddedPerl Bugs

## Bug 1: Comparison operator `<` before variable misinterpreted as readline operator

**Version:** Template::EmbeddedPerl 0.001014

**Description:**
When using the `<` comparison operator before a variable name inside a code block,
the parser/compiler misinterprets it as the start of a `<>` (diamond/readline) operator.

**Error Message:**
```
Internal Server Error: Unterminated <> operator at unknown line 6

5:     my $show_add = $count < $max_options;
6: %>
7: <div class="options-fields">
```

**Minimal Reproduction:**
```perl
use Template::EmbeddedPerl;

my $template = <<'TEMPLATE';
<%
    my $count = 3;
    my $max = 6;
    my $show = $count < $max;
%>
<div>Show: <%= $show %></div>
TEMPLATE

my $ep = Template::EmbeddedPerl->new();
my $compiled = $ep->from_string($template);
my $output = $compiled->render({});
print $output;
```

**Expected:** Template renders with `$show` being true (1)

**Actual:** Error: "Unterminated <> operator"

**Analysis:**
The sequence `< $variable_name` followed by `%>` on a subsequent line appears to
confuse the parser. It seems like `< $max` is being interpreted as the start of
`<$max>` (readline on filehandle `$max`), and the `>` in `%>` is not being
recognized as the closing delimiter.

**Workarounds:**

1. Reverse the comparison:
   ```perl
   my $show = $max > $count;  # instead of $count < $max
   ```

2. Use a literal value:
   ```perl
   my $show = $count < 6;  # instead of $count < $max_options
   ```

3. Use parentheses (may or may not help):
   ```perl
   my $show = ($count < $max);
   ```

**Affected Code Patterns:**
Any `< $variable` comparison inside `<% %>` blocks, especially when the closing
`%>` appears on a following line.
