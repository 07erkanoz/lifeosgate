#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gboolean enforce_frameless_on_map(GtkWidget* widget,
                                         GdkEvent* event,
                                         gpointer user_data) {
  gtk_window_set_decorated(GTK_WINDOW(widget), FALSE);
  return FALSE;
}

static gboolean extract_json_number(const gchar* json,
                                    const gchar* key,
                                    gdouble* out_value) {
  g_return_val_if_fail(json != nullptr, FALSE);
  g_return_val_if_fail(key != nullptr, FALSE);
  g_return_val_if_fail(out_value != nullptr, FALSE);

  g_autofree gchar* pattern =
      g_strdup_printf("\"%s\"\\s*:\\s*([-+]?[0-9]*\\.?[0-9]+)", key);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GRegex) regex =
      g_regex_new(pattern, static_cast<GRegexCompileFlags>(0),
                  static_cast<GRegexMatchFlags>(0), &error);
  if (error != nullptr || regex == nullptr) {
    return FALSE;
  }

  g_autoptr(GMatchInfo) match = nullptr;
  if (!g_regex_match(regex, json, static_cast<GRegexMatchFlags>(0), &match)) {
    return FALSE;
  }

  g_autofree gchar* value_text = g_match_info_fetch(match, 1);
  if (value_text == nullptr || *value_text == '\0') {
    return FALSE;
  }

  gchar* end_ptr = nullptr;
  const gdouble parsed = g_ascii_strtod(value_text, &end_ptr);
  if (end_ptr == value_text) {
    return FALSE;
  }

  *out_value = parsed;
  return TRUE;
}

static gboolean load_initial_window_size(gint* out_width, gint* out_height) {
  g_return_val_if_fail(out_width != nullptr, FALSE);
  g_return_val_if_fail(out_height != nullptr, FALSE);

  const gchar* data_dir = g_get_user_data_dir();
  if (data_dir == nullptr || *data_dir == '\0') {
    return FALSE;
  }

  g_autofree gchar* settings_path =
      g_build_filename(data_dir, APPLICATION_ID, "settings.json", nullptr);
  gchar* settings_json = nullptr;
  gsize settings_len = 0;
  if (!g_file_get_contents(settings_path, &settings_json, &settings_len,
                           nullptr)) {
    return FALSE;
  }

  g_autofree gchar* settings = settings_json;
  if (settings_len == 0) {
    return FALSE;
  }

  gdouble width = 0.0;
  gdouble height = 0.0;
  if (!extract_json_number(settings, "windowWidth", &width) ||
      !extract_json_number(settings, "windowHeight", &height)) {
    return FALSE;
  }

  if (width < 600.0 || height < 400.0 || width > 8192.0 || height > 8192.0) {
    return FALSE;
  }

  *out_width = static_cast<gint>(width);
  *out_height = static_cast<gint>(height);
  return TRUE;
}

static gchar* resolve_launcher_icon_path() {
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) {
    return nullptr;
  }

  g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
  const gchar* candidates[] = {
      "data/flutter_assets/assets/tray_icon.png",
      "data/flutter_assets/assets/tray_icon.ico",
  };

  for (const gchar* rel_path : candidates) {
    g_autofree gchar* candidate = g_build_filename(exe_dir, rel_path, nullptr);
    if (g_file_test(candidate, G_FILE_TEST_EXISTS)) {
      return g_steal_pointer(&candidate);
    }
  }

  return nullptr;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  gint initial_width = 1280;
  gint initial_height = 720;
  load_initial_window_size(&initial_width, &initial_height);

  gtk_window_set_title(window, "LifeOS Gate");
  gtk_window_set_default_size(window, initial_width, initial_height);
  gtk_window_set_decorated(window, FALSE);
  // Some WMs may try to re-enable decorations when the window is mapped.
  // Re-assert frameless right at map time.
  g_signal_connect(window, "map-event", G_CALLBACK(enforce_frameless_on_map),
                   nullptr);

  // Force an empty titlebar so GTK doesn't render a CSD header bar.
  GtkWidget* dummy_titlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_set_size_request(dummy_titlebar, -1, 0);
  gtk_widget_show(dummy_titlebar);
  gtk_window_set_titlebar(window, dummy_titlebar);

  g_autofree gchar* launcher_icon_path = resolve_launcher_icon_path();
  if (launcher_icon_path != nullptr) {
    gtk_window_set_icon_from_file(window, launcher_icon_path, nullptr);
  }

  // Enable RGBA visual so Flutter can render rounded-corner style shell.
  GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(window));
  if (screen != NULL) {
    GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
    if (visual != NULL) {
      gtk_widget_set_visual(GTK_WIDGET(window), visual);
    }
  }
  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  gtk_widget_set_opacity(GTK_WIDGET(window), 1.0);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);

  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  gtk_widget_show(GTK_WIDGET(view));
  // Keep the native window hidden here.
  // It will be shown from Dart (window_manager.show) after restoring
  // geometry/effects, which avoids startup flash and size jump.
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_set_can_focus(GTK_WIDGET(view), TRUE);
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
