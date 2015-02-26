{
open Util
open Trecs_parser
}

let space = [' ' '\t' '\n' '\r']
let digit = ['0'-'9']
let lower = ['a'-'z' '_']
let upper = ['A'-'Z']
let symbol = ['(' ')' '*' '?' '|' '+' ',' '!' ';' '.' ':' '#']

rule header = parse
  "The property is satisfied." { SAFE }
| "The property is not satisfied." { UNSAFE }
| "Verification failed (time out)." { TIMEOUT }
| _ { header lexbuf }
| eof { failwith "lex error" }

and token = parse
  "TRecS" { header lexbuf }
| "The error trace is:" {THE_ERROR_TRACE_IS }
| space+ { token lexbuf }
| "Top" { TOP }
| 'q' digit+
    {
      let s = Lexing.lexeme lexbuf in
      let s1,s2 = String.split_nth s 1 in
      assert (s1 = "q");
      STATE (int_of_string s2)
    }
| '(' { LPAREN }
| ')' { RPAREN }
| ':' { COLON }
| '.' { DOT }
| ',' { COMMA }
| "/\\" { AND }
| "->" { ARROW }
| (lower|upper) (digit|lower|upper)* { IDENT (Lexing.lexeme lexbuf) }
| "The number of expansions:" { footer lexbuf }
| "Elapsed Time:" { footer lexbuf }
| digit+ { INT (int_of_string (Lexing.lexeme lexbuf)) }
| _ { Format.printf "ERROR:%s@." (Lexing.lexeme lexbuf); failwith "lex error" }

and footer = parse
  eof { EOF }
| _ { footer lexbuf }
