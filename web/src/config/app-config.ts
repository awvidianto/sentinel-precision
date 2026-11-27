import packageJson from "../../package.json";

import { t } from "@/i18n";

const currentYear = new Date().getFullYear();

export const APP_CONFIG = {
  name: "Sentinel Precision",
  version: packageJson.version,
  copyright: `© ${currentYear}, Sentinel Precision.`,
  meta: {
    title: t("Sentinel Precision — Autonomous Penetration Testing Console"),
    description: t("Console for the LLM-driven autonomous penetration testing system"),
  },
};
