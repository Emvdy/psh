// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.Text;

namespace Psh.Bootstrapper
{
    internal static class ErrorEnvelope
    {
        internal static void Write(
            string code,
            int exitCode,
            string message,
            string effectivePolicy = null,
            bool? governedByGpo = null,
            string remediation = null)
        {
            StringBuilder json = new StringBuilder();
            json.Append("{\"schemaVersion\":1,\"kind\":\"psh.bootstrapper.error\",\"status\":\"error\"");
            AppendString(json, "code", code);
            json.Append(",\"exitCode\":");
            json.Append(exitCode.ToString(System.Globalization.CultureInfo.InvariantCulture));
            AppendString(json, "message", message);
            if (effectivePolicy != null)
            {
                AppendString(json, "effectivePolicy", effectivePolicy);
            }

            if (governedByGpo.HasValue)
            {
                json.Append(",\"governedByGpo\":");
                json.Append(governedByGpo.Value ? "true" : "false");
            }

            if (remediation != null)
            {
                AppendString(json, "remediation", remediation);
            }

            json.Append('}');
            Console.Out.WriteLine(json.ToString());
        }

        private static void AppendString(StringBuilder json, string name, string value)
        {
            json.Append(",\"");
            json.Append(Escape(name));
            json.Append("\":\"");
            json.Append(Escape(value ?? string.Empty));
            json.Append('"');
        }

        private static string Escape(string value)
        {
            StringBuilder escaped = new StringBuilder(value.Length + 8);
            foreach (char character in value)
            {
                switch (character)
                {
                    case '\\':
                        escaped.Append("\\\\");
                        break;
                    case '"':
                        escaped.Append("\\\"");
                        break;
                    case '\r':
                        escaped.Append("\\r");
                        break;
                    case '\n':
                        escaped.Append("\\n");
                        break;
                    case '\t':
                        escaped.Append("\\t");
                        break;
                    default:
                        if (character < 0x20)
                        {
                            escaped.Append("\\u");
                            escaped.Append(((int)character).ToString("x4", System.Globalization.CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            escaped.Append(character);
                        }

                        break;
                }
            }

            return escaped.ToString();
        }
    }
}
