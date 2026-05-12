import ThemeSegmented from '../theme/theme-segmented'

export default function AppearancePage() {
  return (
    <section>
      <h1 className="mb-4 text-xl font-semibold text-gray-900 dark:text-gray-100">Appearance</h1>
      <fieldset className="space-y-2">
        <legend className="text-sm font-medium text-gray-700 dark:text-gray-200">Theme</legend>
        <ThemeSegmented />
        <p className="text-xs text-gray-500 dark:text-gray-400">
          System follows your operating system preference.
        </p>
      </fieldset>
    </section>
  )
}
