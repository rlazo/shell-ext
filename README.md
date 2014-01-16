shell-ext
=========

shell-ext enhances shell-mode with better extensibility by adding a
command processing pipeline. This pipeline enables the execution of
custom code before sending commands to the underlying shell
process. It also enables command interception, so you could invoke
emacs functions from the shell, e.g. issuing the command "man
emacs" can launch emacs' man-mode instead of the actual man
program.

Usage
------

Put shell-ext.el anywhere in your load-path and then require it.

    (require 'shell-ext)

that's it!
