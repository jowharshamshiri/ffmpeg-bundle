/// The end of what the recipe said, as the failure should quote it.
///
/// Both streams, because the two carry different halves of the story: the
/// recipe's own progress and its `ok:` lines go to stdout, while make, cl.exe
/// and MSYS2 write the actual error to stderr. A message carrying one of them
/// describes half a failure.
///
/// The TAIL, because an ffmpeg build prints thousands of lines and the
/// interesting part of a log about something that stopped is the end of it.
fn recipe_tail(stdout: &[u8], stderr: &[u8]) -> String {
    /// Enough to carry a compiler error and the make context around it, and
    /// short enough that the panic is still readable in a terminal.
    const LINES: usize = 60;

    let mut parts = Vec::new();
    for (name, stream) in [("stdout", stdout), ("stderr", stderr)] {
        let text = String::from_utf8_lossy(stream);
        let trimmed = text.trim_end();
        if trimmed.is_empty() {
            continue;
        }
        let lines: Vec<&str> = trimmed.lines().collect();
        let tail = if lines.len() > LINES {
            // Said, rather than silently truncated: a reader who cannot see
            // that the top is missing goes looking for a beginning that was cut
            // off rather than opening the full log.
            format!(
                "  ({} earlier lines not shown)\n{}",
                lines.len() - LINES,
                lines[lines.len() - LINES..].join("\n")
            )
        } else {
            lines.join("\n")
        };
        parts.push(format!("[{name}]\n{tail}"));
    }
    if parts.is_empty() {
        // Not "look above": there is nothing above. A recipe that failed
        // saying nothing at all is itself the finding.
        return "(the recipe wrote nothing to either stream before it failed)".to_string();
    }
    parts.join("\n\n")
}
