;;; zenscript-language.el --- Tools for understanding ZenScript code. -*- lexical-binding: t -*-

;; Copyright (c) 2020 Eutro

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; ZenScript language module, for parsing and understanding ZenScript.

;;; Code:

(require 'zenscript-common)

(defun zenscript--java-type-to-ztype (symbol)
  "Convert a Java type to a ZenType.

SYMBOL should be a java class name to be looked up in dumpzs."
  (car
   (seq-find (lambda (entry)
	       (equal (cadr entry) symbol))
	     (cdr (assoc "Types" (cdr (zenscript-get-dumpzs)))))))

(defun zenscript--symbol-to-type (symbol)
  "Get the ZenType from a stringified binding object SYMBOL.

If SYMBOL is the string:

 \"SymbolJavaStaticField: public static zenscript.Type ZenScriptGlobals.global\"

Then its ZenType will be resolved by looking up the zsPath of \"zenscript.Type\"."
  (when (string-match "SymbolJavaStatic\\(?:Field\\|\\(Method: JavaMethod\\)\\): public static \\(.+\\) .+$" symbol)
    (concat (if (match-string 1) "=>" "") (zenscript--java-type-to-ztype (match-string 2 symbol)))))

(defun zenscript--buffer-vals ()
  "Get a list of resolvable values in a buffer.

Returns a list of values of the form:

 (name type)

name:

  The name of the value by which it can be referenced.

type:

  The ZenType of the value, its `zsPath` from dumpzs, or nil if unknown."
  (mapcar (lambda (el)
	    (list (car el)
		  (zenscript--symbol-to-type (cadr el))))
	  (cdr (assoc "Globals" (cdr (zenscript-get-dumpzs))))))

(defun zenscript--get-importables-1 (nodes)
  "Get a list of types or static members below NODES in the tree."
  (apply 'append
	 (mapcar (lambda (node)
		   (if (stringp node)
		       (list node)
		     (let ((name (car node)))
		       ;; This operates on the assumption that type names start
		       ;; with capital letters.
		       (if (string= "Lu" (get-char-code-property (string-to-char name)
								 'general-category))
			   (cons name
				 (mapcar (lambda (member)           ; "[STATIC] "
					   (concat name "." (substring member 9)))
					 (seq-filter (lambda (member)
						       (string-match-p "\\[STATIC\\] .+" member))
						     (mapcar (lambda (node)
							       (if (stringp node)
								   node
								 (car node)))
							     (cdr node)))))
			 (mapcar (lambda (importable)
				   (concat name "." importable))
				 (zenscript--get-importables-1 (cdr node)))))))
		 nodes)))

(defun zenscript--get-members (&optional types)
  "Get the known members of the ZenTypes TYPES, or just all known members.

Returns a list of members of the following format:

 (name . extra-info)

name:

  The name of the member.

extra-info:

  A list (possibly nil) of extra information relating to the member."
  (if types
      ()
    (apply 'append
	   (mapcar (lambda (type)
		     (cdr (assoc 'members type)))
		   (cdr (assoc 'zenTypeDumps (car (zenscript-get-dumpzs))))))))

(defun zenscript--get-importables ()
  "Get a list of all things that can be imported: static members and types.

Returns a list of type names that can be imported."
  (zenscript--get-importables-1 (cdr (assoc "Root (Symbol Package)" (cdr (zenscript-get-dumpzs))))))

;;; Parsing:

;; I have written these too many times, so I'm keeping them around.

(defun zenscript--skip-ws-and-comments ()
  "Skip across any whitespace characters or comments."
  (skip-syntax-forward " >")
  (when (char-after)
    (let ((ppss (save-excursion
		  (parse-partial-sexp (point)
				      (+ (point) 2)
				      () () () t))))
      (when (nth 4 ppss)
	(parse-partial-sexp (point)
			    (point-max)
			    () () ppss 'syntax-table)
	(zenscript--skip-ws-and-comments)))))

(defun zenscript--looking-at-backwards-p (regex)
  "Return non-nil if searching REGEX backwards ends at point."
  (= (point)
     (save-excursion
       (or (and (re-search-backward regex (point-min) t)
		(match-end 0))
	   0))))

(defun zenscript--tokenize-buffer (&optional from to no-error)
  "Read the buffer into a list of tokens.

FROM is the start position, and defaults to `point-min`.

TO is the end position, and defaults to `point-max`.

If a token is unrecognised, and NO-ERROR is nil, an error is thrown.
If NO-ERROR is non-nil, then parsing stops instead, returning the partially
accumulated list of tokens, and leaving point where it is.

If parsing concludes, then point is left at TO.

Note: this uses the syntax table to handle comments."
  (goto-char (or from (point-min)))
  (let ((to (or to (point-max)))
	(continue t)
	tokens)
    (zenscript--skip-ws-and-comments)
    (while (and continue (char-after))
      (let ((start (point))
	    (next-token (zenscript--next-token)))
	(when (or (>= (point) to)
		  (not next-token))
	  (setq continue ()))
	(if next-token
	    (if (> (point) to)
		(goto-char start)
	      (setq tokens (cons next-token tokens))
	      (when (< (point) to)
		(zenscript--skip-ws-and-comments)))
	  (unless no-error
	    (error "%s" "Unrecognised token")))))
    (reverse tokens)))

(defconst zenscript--keyword-map
  (let ((table (make-hash-table :size 34
				:test 'equal)))
    (puthash "frigginConstructor" 'T_ZEN_CONSTRUCTOR table)
    (puthash "zenConstructor" 'T_ZEN_CONSTRUCTOR table)
    (puthash "frigginClass" 'T_ZEN_CLASS table)
    (puthash "zenClass" 'T_ZEN_CLASS table)
    (puthash "instanceof" 'T_INSTANCEOF table)
    (puthash "static" 'T_STATIC table)
    (puthash "global" 'T_GLOBAL table)
    (puthash "import" 'T_IMPORT table)
    (puthash "false" 'T_FALSE table)
    (puthash "true" 'T_TRUE table)
    (puthash "null" 'T_NULL table)
    (puthash "break" 'T_BREAK table)
    (puthash "while" 'T_WHILE table)
    (puthash "val" 'T_VAL table)
    (puthash "var" 'T_VAR table)
    (puthash "return" 'T_RETURN table)
    (puthash "for" 'T_FOR table)
    (puthash "else" 'T_ELSE table)
    (puthash "if" 'T_IF table)
    (puthash "version" 'T_VERSION table)
    (puthash "as" 'T_AS table)
    (puthash "void" 'T_VOID table)
    (puthash "has" 'T_IN table)
    (puthash "in" 'T_IN table)
    (puthash "function" 'T_FUNCTION table)
    (puthash "string" 'T_STRING table)
    (puthash "double" 'T_DOUBLE table)
    (puthash "float" 'T_FLOAT table)
    (puthash "long" 'T_LONG table)
    (puthash "int" 'T_INT table)
    (puthash "short" 'T_SHORT table)
    (puthash "byte" 'T_BYTE table)
    (puthash "bool" 'T_BOOL table)
    (puthash "any" 'T_ANY table)
    table)
  "A hash-table of keywords to tokens.")

(defun zenscript--next-token (&optional skip-whitespace)
  "Parse the next ZenScript token after point.

If SKIP-WHITESPACE is non-nil, whitespace and comments
are skipped according to `syntax-table`.

Return a pair of the form

 (type val pos)

or nil if no token was recognised.

type:

  The type of the token, as seen here
  https://docs.blamejared.com/1.12/en/Dev_Area/ZenTokens/

val:

  The string value of the token.

pos:

  The position at which the token occured.

point is put after token, if one was found."
  (let ((begin (point)))
    (when skip-whitespace (zenscript--skip-ws-and-comments))
    (if-let ((type (cond ((looking-at "[a-zA-Z_][a-zA-Z_0-9]*")
			  (or (gethash (buffer-substring-no-properties (match-beginning 0)
								       (match-end 0))
				       zenscript--keyword-map)
			      'T_ID))
			 ((looking-at (regexp-quote "{")) 'T_AOPEN)
			 ((looking-at (regexp-quote "}")) 'T_ACLOSE)
			 ((looking-at (regexp-quote "[")) 'T_SQBROPEN)
			 ((looking-at (regexp-quote "]")) 'T_SQBRCLOSE)
			 ((looking-at (regexp-quote "..")) 'T_DOT2)
			 ((looking-at (regexp-quote ".")) 'T_DOT)
			 ((looking-at (regexp-quote ",")) 'T_COMMA)
			 ((looking-at (regexp-quote "+=")) 'T_PLUSASSIGN)
			 ((looking-at (regexp-quote "+")) 'T_PLUS)
			 ((looking-at (regexp-quote "-=")) 'T_MINUSASSIGN)
			 ((looking-at (regexp-quote "-")) 'T_MINUS)
			 ((looking-at (regexp-quote "*=")) 'T_MULASSIGN)
			 ((looking-at (regexp-quote "*")) 'T_MUL)
			 ((looking-at (regexp-quote "/=")) 'T_DIVASSIGN)
			 ((looking-at (regexp-quote "/")) 'T_DIV)
			 ((looking-at (regexp-quote "%=")) 'T_MODASSIGN)
			 ((looking-at (regexp-quote "%")) 'T_MOD)
			 ((looking-at (regexp-quote "|=")) 'T_ORASSIGN)
			 ((looking-at (regexp-quote "|")) 'T_OR)
			 ((looking-at (regexp-quote "||")) 'T_OR2)
			 ((looking-at (regexp-quote "&=")) 'T_ANDASSIGN)
			 ((looking-at (regexp-quote "&&")) 'T_AND2)
			 ((looking-at (regexp-quote "&")) 'T_AND)
			 ((looking-at (regexp-quote "^=")) 'T_XORASSIGN)
			 ((looking-at (regexp-quote "^")) 'T_XOR)
			 ((looking-at (regexp-quote "?")) 'T_QUEST)
			 ((looking-at (regexp-quote ":")) 'T_COLON)
			 ((looking-at (regexp-quote "(")) 'T_BROPEN)
			 ((looking-at (regexp-quote ")")) 'T_BRCLOSE)
			 ((looking-at (regexp-quote "~=")) 'T_TILDEASSIGN)
			 ((looking-at (regexp-quote "~")) 'T_TILDE)
			 ((looking-at (regexp-quote ";")) 'T_SEMICOLON)
			 ((looking-at (regexp-quote "<=")) 'T_LTEQ)
			 ((looking-at (regexp-quote "<")) 'T_LT)
			 ((looking-at (regexp-quote ">=")) 'T_GTEQ)
			 ((looking-at (regexp-quote ">")) 'T_GT)
			 ((looking-at (regexp-quote "==")) 'T_EQ)
			 ((looking-at (regexp-quote "=")) 'T_ASSIGN)
			 ((looking-at (regexp-quote "!=")) 'T_NOTEQ)
			 ((looking-at (regexp-quote "!")) 'T_NOT)
			 ((looking-at (regexp-quote "$")) 'T_DOLLAR)
			 ((or (looking-at "-?\\(0\\|[1-9][0-9]*\\)")
			      (looking-at "0x[a-fA-F0-9]*"))
			  'T_INTVALUE)
			 ((looking-at "-?\\(0\\|[1-9][0-9]*\\)\\.[0-9]+\\([eE][+-]?[0-9]+\\)?[fFdD]?")
			  'T_FLOATVALUE)
			 ((or (looking-at "'\\([^'\\\\]\\|\\\\\\(['\"\\\\/bfnrt]\\|u[0-9a-fA-F]{4}\\)\\)*?'")
			      (looking-at "\"\\([^\"\\\\]\\|\\\\\\(['\"\\\\/bfnrt]\\|u[0-9a-fA-F]{4}\\)\\)*\""))
			  'T_STRINGVALUE))))
	(progn (goto-char (match-end 0))
	       (list type
		     (buffer-substring-no-properties (match-beginning 0)
						     (match-end 0))
		     (match-beginning 0)))
      (goto-char begin)
      ())))

(defmacro cdr! (list)
  "Set LIST to the cdr of LIST."
  `(setq ,list (cdr ,list)))

(defun zenscript--make-tokenstream (token-list)
  "Make a tokenstream from a list of tokens, TOKEN-LIST."
  (lambda (op &rest args)
    (pcase op
      ('PEEK (car token-list))
      ('NEXT (prog1 (car token-list)
	       (cdr! token-list)))
      ('OPTIONAL (when (eq (car args) (caar token-list))
		   (prog1 (car token-list)
		     (cdr! token-list))))
      ('REQUIRE (if (eq (car args) (caar token-list))
		    (prog1 (car token-list)
		      (cdr! token-list))
		  (throw 'zenscript-parse-error
			 (cadr args))))
      ('HAS-NEXT (if token-list t)))))

(defun zenscript--require-token (type tokens message)
  "Require that the next token in TOKENS is of type TYPE.

Return the first token if it is of type TYPE, otherwise
throw 'zenscript-parse-error with MESSAGE.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'REQUIRE type message))

(defun zenscript--peek-token (tokens)
  "Look at the next token in the stream TOKENS, without consuming it.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'PEEK))

(defun zenscript--get-token (tokens)
  "Get the next token in the stream TOKENS, consuming it.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'NEXT))

(defun zenscript--optional-token (type tokens)
  "Get the next token in the stream TOKENS if it is of the type TYPE, or nil.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'OPTIONAL type))

(defun zenscript--has-next-token (tokens)
  "Return t if TOKENS has any more tokens remaining.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'HAS-NEXT))

(defun zenscript--parse-tokens (tokenlist)
  "Parse a list of ZenScript tokens.

TOKENLIST is a list of tokens of the form

 (type val pos)

As returned by `zenscript--next-token`.

Returns a list of the form

 (imports functions . statements)

Which are lists of elements of the formats:

imports:

  (fqname pos rename)

  fqname:

    A list of strings representing the fully qualified name.

  pos:

    The position at which the import appears.

  rename:

    The name by which fqname should be referenced, or nil
    if the last name in fqname should be used."
  (let ((tokens (zenscript--make-tokenstream tokenlist))
	imports functions statements)
    (while (and (zenscript--has-next-token tokens)
		(eq (car (zenscript--peek-token tokens))
		    'T_IMPORT))
      (let (fqname
	    (pos (caddr (zenscript--get-token tokens)))
	    rename)

	(setq fqname
	      (cons
	       (cadr (zenscript--require-token 'T_ID tokens
					       "identifier expected"))
	       fqname))
	(while (zenscript--optional-token 'T_DOT tokens)
	  (setq fqname
		(cons
		 (cadr (zenscript--require-token 'T_ID tokens
						 "identifier expected"))
		 fqname)))

	(when (zenscript--optional-token 'T_AS tokens)
	  (setq rename (cadr (zenscript--require-token 'T_ID tokens
						       "identifier expected"))))

	(zenscript--require-token 'T_SEMICOLON tokens
				  "; expected")

	(setq imports (cons (list (reverse fqname)
				  pos
				  rename)
			    imports))))
    (while (zenscript--has-next-token tokens)
      (pcase (car (zenscript--peek-token tokens))
	((or 'T_GLOBAL 'T_STATIC)
	 (setq statements
	       (cons
		(zenscript--parse-global tokens)
		statements)))
	('T_FUNCTION)
	('T_ZENCLASS)))
    (list (reverse imports)
	  (reverse functions)
	  (reverse statements))))

(defun zenscript--parse-zentype (tokens)
  "Parse the next ZenType from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((next (zenscript--get-token tokens))
	base)
    (pcase (car next)
      ('T_ANY (setq base '(RAW "any")))
      ('T_VOID (setq base '(RAW "void")))
      ('T_BOOL (setq base '(RAW "bool")))
      ('T_BYTE (setq base '(RAW "byte")))
      ('T_SHORT (setq base '(RAW "short")))
      ('T_INT (setq base '(RAW "int")))
      ('T_LONG (setq base '(RAW "long")))
      ('T_FLOAT (setq base '(RAW "float")))
      ('T_DOUBLE (setq base '(RAW "double")))
      ('T_STRING (setq base '(RAW "string")))
      ('T_ID
       (let ((type-name (cadr next)))
	 (while (zenscript--optional-token 'T_DOT tokens)
	   (setq type-name
		 (concat type-name "."
			 (cadr (zenscript--require-token 'T_ID tokens
							 "identifier expected")))))
	 (setq base (list 'RAW type-name))))
      ('T_FUNCTION
       (let (argument-types)
	 (zenscript--require-token 'T_BROPEN tokens
				   "( required")
	 (unless (zenscript--optional-token 'T_BRCLOSE tokens)
	   (setq argument-types
		 (cons (zenscript--parse-zentype tokens) argument-types))
	   (while (zenscript--optional-token 'T_COMMA tokens)
	     (setq argument-types
		   (cons (zenscript--parse-zentype tokens) argument-types)))
	   (zenscript--require-token 'T_BRCLOSE tokens
				     ") required"))
	 (setq base (list 'FUNCTION (reverse argument-types) (zenscript--parse-zentype tokens)))))
      ('T_SQBROPEN
       (setq base (list 'LIST (zenscript--parse-zentype tokens)))
       (zenscript--require-token 'T_SQBRCLOSE tokens "] expected"))
      (_ (throw 'zenscript-parse-error (format "Unknown type: %s" (cadr next)))))
    (while (zenscript--optional-token 'T_SQBROPEN tokens)
      (if (zenscript--optional-token 'T_SQBRCLOSE tokens)
	  (setq base (list 'ARRAY base))
	(setq base (list 'ASSOCIATIVE base (zenscript--parse-zentype tokens)))
	(zenscript--require-token 'T_SQBRCLOSE tokens
				  "] expected")))
    base))

(defun zenscript--parse-expression (tokens)
  "Parse the next expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((token (zenscript--peek-token tokens))
	position left)
    (unless token
      (throw 'zenscript-parse-error
	     "Unexpected end of file."))
    (setq position (cadr token))
    (setq left (zenscript--parse-conditional tokens))
    (unless (zenscript--peek-token tokens)
      (throw 'zenscript-parse-error
	     "Unexpected end of file."))

    (or (pcase (car (zenscript--peek-token tokens))
	  ('T_ASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_ASSIGN left (zenscript--parse-expression tokens)))
	  ('T_PLUSASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'ADD left (zenscript--parse-expression tokens)))
	  ('T_MINUSASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'SUB left (zenscript--parse-expression tokens)))
	  ('T_TILDEASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'CAT left (zenscript--parse-expression tokens)))
	  ('T_MULASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'MUL left (zenscript--parse-expression tokens)))
	  ('T_DIVASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'DIV left (zenscript--parse-expression tokens)))
	  ('T_MODASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'MOD left (zenscript--parse-expression tokens)))
	  ('T_ORASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'OR left (zenscript--parse-expression tokens)))
	  ('T_ANDASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'AND left (zenscript--parse-expression tokens)))
	  ('T_XORASSIGN:
	   (zenscript--next-token tokens)
	   (list 'E_OPASSIGN 'XOR left (zenscript--parse-expression tokens)))
	  (_ ()))
	left)))

(defun zenscript--parse-conditional (tokens)
  "Possibly read a conditional expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let (left (zenscript--parse-or-or tokens))
    (if-let (quest (zenscript--optional-token 'T_QUEST tokens))
	(list 'E_CONDITIONAL
	      (zenscript--parse-or-or-expression tokens)
	      (progn (zenscript--require-token 'T_COLON tokens
					       ": expected")
		     (zenscript--read-conditional tokens))
	      (caddr quest))
      left)))

(defmacro zenscript--parse-binary (token-type expression-type parse-next)
  "Macro for the binary expressions below.

TOKEN-TYPE is the token representing this operation.

EXPRESSION-TYPE is the type of the expression that may
be parsed.

PARSE-NEXT is the function to delegate to."
  `(let (left (~parse-next tokens))
     (while (zenscript--optional-token '~token-type tokens)
       (setq left
	     (list '~expression-type left
		   (~parse-next tokens))))
     left))

(defun zenscript--parse-or-or (tokens)
  "Possibly read an expression using ||s from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary T_OR2 E_OR2
			   zenscript--parse-and-and))

(defun zenscript--parse-and-and (tokens)
  "Possibly read an expression using &&s from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary T_AND2 E_AND2
			   zenscript--parse-or))

(defun zenscript--parse-or (tokens)
  "Possibly read an expression using |s from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary T_OR E_OR
			   zenscript--parse-or))

(defun zenscript--parse-xor (tokens)
  "Possibly read an expression using ^s from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary T_XOR E_XOR
			   zenscript--parse-and))

(defun zenscript--parse-and (tokens)
  "Possibly read an expression using &s from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary T_AND E_AND
			   zenscript--parse-comparison))

(defun zenscript--parse-comparison (tokens)
  "Possibly read a comparison expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((left (zenscript--parse-add tokens))
	(type (pcase (car (zenscript--peek-token tokens))
		('T_EQ 'C_EQ)
		('T_NOTEQ 'C_NE)
		('T_LT 'C_LT)
		('T_LTEQ 'C_LE)
		('T_GT 'C_GT)
		('T_GTEQ 'C_GE)
		('T_IN
		 (setq left
		       (list 'E_BINARY left
			     (zenscript--parse-add tokens)
			     'O_CONTAINS))
		 ;; doesn't count as a comparison
		 ;; but it's still here for some reason.
		 ()))))
    (if type
	(list 'E_ADD left
	      (zenscript--parse-add tokens)
	      type)
      left)))

(defun zenscript--parse-add (tokens)
  "Possibly read an addition-priority expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((left (zenscript--parse-mul)))
    (while (progn
	     (cond ((zenscript--optional-token 'T_PLUS)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-mul tokens)
				     'O_ADD)))
		   ((zenscript--optional-token 'T_MINUS)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-mul tokens)
				     'O_SUB)))
		   ((zenscript--optional-token 'T_TILDE)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-mul tokens)
				     'O_CAT)))
		   (t ()))))
    left))

(defun zenscript--parse-mul (tokens)
  "Possibly read an multiplication-priority expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((left (zenscript--parse-unary)))
    (while (progn
	     (cond ((zenscript--optional-token 'T_MUL)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-unary tokens)
				     'O_MUL)))
		   ((zenscript--optional-token 'T_DIV)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-unary tokens)
				     'O_DIV)))
		   ((zenscript--optional-token 'T_MOD)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-unary tokens)
				     'O_MOD)))
		   (t ()))))
    left))

(defun zenscript--parse-unary (tokens)
  "Possibly read a unary expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (pcase (car (zenscript--peek-token tokens))
    ('T_NOT (list 'E_UNARY
		  (zenscript--parse-unary tokens)
		  'O_NOT))
    ('T_MINUS (list 'E_UNARY
		    (zenscript--parse-unary tokens)
		    'O_MINUS))
    (_ (zenscript--parse-postfix tokens))))

(defun zenscript--parse-postfix (tokens)
  "Possibly read a postfix expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((base (zenscript--parse-primary tokens)))
    (while
	(and (zenscript--peek-token tokens)
	     (cond
	      ((zenscript--optional-token 'T_DOT tokens)
	       (let ((member (or (zenscript--optional-token 'T_ID tokens)
				 ;; what even is this
				 (zenscript--optional-token 'T_VERSION tokens))))
		 (setq base
		       (list 'E_MEMBER base
			     (if member
				 (cadr member)
			       (substring (cadr
					   ;; why
					   (or (zenscript--optional-token 'T_STRING)
					       (throw 'zenscript-parse-error
						      "Invalid expression.")))
					  1 -1))))
		 ()))
	      ((or (zenscript--optional-token 'T_DOT2)
		   (and (string-equal
			 "to"
			 (cadr (zenscript--optional-token 'T_ID)))))
	       (setq base
		     (list 'E_BINARY base
			   (zenscript--parse-expression tokens)
			   'O_RANGE))
	       ()))))
    base))

(defun zenscript--parse-primary (tokens)
  "Read a primary expression from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  )

(defun zenscript--parse-global (tokens)
  "Parse the next global definition from TOKENS.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((pos (caddr (zenscript--get-token tokens)))
	(name (cadr (zenscript--require-token 'T_ID tokens
					      "Global value requires a name!")))
	(type (if (zenscript--optional-token 'T_AS tokens)
		  (zenscript--parse-zentype tokens)
		  '(RAW "any")))
	(value (progn (zenscript--require-token 'T_ASSIGN tokens
						"Global values have to be initialized!")
		      (zenscript--parse-expression tokens))))
    (zenscript--require-token 'T_SEMICOLON tokens
			      "; expected")
    (list 'S_GLOBAL name type value)))

(provide 'zenscript-language)
;;; zenscript-language.el ends here
