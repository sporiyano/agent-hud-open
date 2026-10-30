/// Splits a Windows command line into its arguments the way the Microsoft C runtime does for `argv`, since Windows
/// keeps a process's arguments as one string. The program name ends at the next quote when it starts with one, and
/// otherwise at the first space, with no escapes; the other arguments follow the runtime's backslash and quote rules.
enum WindowsCommandLine {
    static func arguments(_ line: String) -> [String] {
        let characters = Array(line)
        var index = 0, result: [String] = []

        func skipSpace() { while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 } }

        skipSpace()
        guard index < characters.count else { return [] }
        var program = ""
        if characters[index] == "\"" {
            index += 1
            while index < characters.count, characters[index] != "\"" { program.append(characters[index]); index += 1 }
            index += 1
        }
        while index < characters.count, characters[index] != " ", characters[index] != "\t" {
            program.append(characters[index]); index += 1
        }
        result.append(program)

        while true {
            skipSpace()
            guard index < characters.count else { return result }
            var argument = "", quoted = false
            while index < characters.count {
                let character = characters[index]
                if !quoted, character == " " || character == "\t" { break }
                if character == "\\" {
                    var slashes = 0
                    while index < characters.count, characters[index] == "\\" { slashes += 1; index += 1 }
                    if index < characters.count, characters[index] == "\"" {
                        argument += String(repeating: "\\", count: slashes / 2)
                        if slashes % 2 == 1 { argument.append("\""); index += 1 }
                    } else {
                        argument += String(repeating: "\\", count: slashes)
                    }
                    continue
                }
                if character == "\"" {
                    if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                        argument.append("\""); index += 2
                    } else {
                        quoted.toggle(); index += 1
                    }
                    continue
                }
                argument.append(character); index += 1
            }
            result.append(argument)
        }
    }
}
