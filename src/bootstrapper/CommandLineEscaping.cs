// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.Collections.Generic;
using System.Text;

namespace Psh.Bootstrapper
{
    /// <summary>Quotes arguments for CreateProcess without invoking a shell.</summary>
    internal static class CommandLineEscaping
    {
        internal static string Join(IEnumerable<string> arguments)
        {
            if (arguments == null)
            {
                throw new ArgumentNullException("arguments");
            }

            StringBuilder builder = new StringBuilder();
            bool first = true;
            foreach (string argument in arguments)
            {
                if (!first)
                {
                    builder.Append(' ');
                }

                builder.Append(Quote(argument));
                first = false;
            }

            return builder.ToString();
        }

        internal static string Quote(string value)
        {
            if (value == null)
            {
                throw new ArgumentNullException("value");
            }

            if (value.Length != 0 && value.IndexOfAny(new[] { ' ', '\t', '\r', '\n', '"' }) < 0)
            {
                return value;
            }

            StringBuilder builder = new StringBuilder(value.Length + 2);
            builder.Append('"');
            int backslashes = 0;
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }

                if (character == '"')
                {
                    builder.Append('\\', (backslashes * 2) + 1);
                    builder.Append('"');
                    backslashes = 0;
                    continue;
                }

                if (backslashes != 0)
                {
                    builder.Append('\\', backslashes);
                    backslashes = 0;
                }

                builder.Append(character);
            }

            if (backslashes != 0)
            {
                builder.Append('\\', backslashes * 2);
            }

            builder.Append('"');
            return builder.ToString();
        }
    }
}
