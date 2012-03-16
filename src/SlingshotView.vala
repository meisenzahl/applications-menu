// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
//
//  Copyright (C) 2011 Giulio Collura
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Gtk;
using Gdk;
using Gee;
using Cairo;
using Granite.Widgets;
using GMenu;

using Slingshot.Widgets;
using Slingshot.Backend;

namespace Slingshot {

    public enum Modality {
        NORMAL_VIEW = 0,
        CATEGORY_VIEW = 1,
        SEARCH_VIEW
    }

    public class SlingshotView : PopOver {

        // Widgets
        public SearchBar searchbar;
        public Slider view_manager;
        public Switcher page_switcher;
        public ModeButton view_selector;

        // Views
        private Widgets.Grid grid_view;
        private SearchView search_view;
        private CategoryView category_view;

        public HBox top;
        public HBox center;
        public HBox bottom;
        public VBox container;

        public AppSystem app_system;
        private ArrayList<TreeDirectory> categories;
        public HashMap<string, ArrayList<App>> apps;

        private int current_position = 0;
        private int search_view_position = 0;
        private Modality modality;

        // Sizes
        public int columns {
            get {
                return grid_view.get_page_columns ();
            }
        }
        public int rows {
            get {
                return grid_view.get_page_rows ();
            }
        }
        private int default_columns;
        private int default_rows;

        public int view_height {
            get {
                return (int) (rows*130 + rows*grid_view.row_spacing + 35);
            }
        }

        public SlingshotView () {

            // Window properties
            this.title = "Slingshot";
            this.skip_pager_hint = true;
            this.skip_taskbar_hint = true;
            set_keep_above (true);

            // Have the window in the right place
            read_settings (true);
            height_request = default_rows * 145 + 180;

            Slingshot.icon_theme = IconTheme.get_default ();

            app_system = new AppSystem ();

            categories = app_system.get_categories ();
            apps = app_system.get_apps ();
            setup_ui ();
            connect_signals ();

            debug ("Apps loaded");

        }

        private void setup_ui () {

            debug ("In setup_ui ()");

            // Create the base container
            container = new VBox (false, 0);

            // Add top bar
            top = new HBox (false, 10);

            view_selector = new ModeButton ();
            view_selector.append (new Image.from_icon_name ("slingshot-view-list-icons-symbolic", IconSize.MENU));
            view_selector.append (new Image.from_icon_name ("slingshot-view-list-filter-symbolic", IconSize.MENU));
            view_selector.selected = 0;

            searchbar = new SearchBar (_("Search Apps..."));
            searchbar.pause_delay = 200;
            searchbar.width_request = 250;

            if (Slingshot.settings.show_category_filter) {
                top.pack_start (view_selector, false, false, 0);
            }
            top.pack_end (searchbar, false, false, 0);

            center = new HBox (false, 0);
            // Create the layout which works like view_manager
            view_manager = get_slider ();
            view_manager.set_size_request (default_columns*130, default_rows*145);
            center.pack_end (view_manager, true, true, 0);

            // Create the "NORMAL_VIEW"
            grid_view = new Widgets.Grid (default_rows, default_columns);
            //view_manager.put (grid_view, 0, 0);

            // Create the "SEARCH_VIEW"
            search_view = new SearchView (this);
            foreach (ArrayList<App> app_list in apps.values) {
                search_view.add_apps (app_list);
            }
            //view_manager.put (search_view, -columns*130, 0);

            // Create the "CATEGORY_VIEW"
            category_view = new CategoryView (this);
            //view_manager.put (category_view, -columns*130, 0);

            // Create the page switcher
            page_switcher = new Switcher ();

            // A bottom widget to keep the page switcher center
            bottom = new HBox (false, 0);
            bottom.pack_start (new Label (""), true, true, 0); // A fake label
            bottom.pack_start (page_switcher, false, false, 0);
            bottom.pack_end (new Label (""), true, true, 0); // A fake label

            container.pack_start (Utils.set_padding (top, 12, 12, 12, 12), false, true, 0);
            container.pack_start (Utils.set_padding (center, 0, 12, 12, 12),
                                                     true, true, 0);
            container.pack_end (Utils.set_padding (bottom, 0, 24, 12, 24), false, true, 0);

            // Add the container to the dialog's content area
            var content_area = get_content_area () as Box;
            content_area.pack_start (container);

            set_modality (Modality.NORMAL_VIEW);
            debug ("Ui setup completed");

        }

        private void connect_signals () {

            this.focus_out_event.connect (() => {
                this.hide_slingshot();
                return false;
            });

            this.focus_in_event.connect (() => {
                searchbar.grab_focus ();
                return false;
            });

            //view_manager.draw.connect (this.draw_background);

            searchbar.text_changed_pause.connect ((text) => this.search (text.down ().strip ()));
            searchbar.grab_focus ();

            search_view.app_launched.connect (hide_slingshot);

            // This function must be after creating the page switcher
            grid_view.new_page.connect (page_switcher.append);
            populate_grid_view ();

            page_switcher.active_changed.connect (() => {

                if (page_switcher.active > page_switcher.old_active)
                    this.page_right (page_switcher.active);
                else
                    this.page_left (page_switcher.active);

            });

            view_selector.mode_changed.connect (() => {

                set_modality ((Modality) view_selector.selected);

            });

            // Auto-update settings when changed
            //Slingshot.settings.changed.connect (() => read_settings ());

            // Auto-update applications grid
            app_system.changed.connect (() => {

                categories = app_system.get_categories ();
                apps = app_system.get_apps ();

                populate_grid_view ();

            });

            // position on the right monitor when settings changed
            screen.size_changed.connect (() => {
                reposition ();
            });
            screen.monitors_changed.connect (() => {
                reposition ();
            });

        }

        private void reposition () {

            debug("Repositioning");

            if (Slingshot.settings.open_on_mouse)
                window_position = WindowPosition.MOUSE;
            else {
                Gdk.Rectangle monitor_dimensions;
                screen.get_monitor_geometry (this.screen.get_primary_monitor(), out monitor_dimensions);

                move_to_coords (monitor_dimensions.x, monitor_dimensions.y); //this would be coordinates 0,0 on the screen
            }
        }

        public override bool key_press_event (Gdk.EventKey event) {

            switch (Gdk.keyval_name (event.keyval)) {

                case "Escape":
                    hide_slingshot ();
                    return true;

                case "Return":
                    if (modality == Modality.SEARCH_VIEW) {
                        search_view.launch_selected ();
                        hide_slingshot ();
                    }
                    return true;

                case "Alt":
                    break;

                case "Tab":
                    if (modality == Modality.NORMAL_VIEW)
                        view_selector.selected = 1;
                    else if (modality == Modality.CATEGORY_VIEW)
                        view_selector.selected = 0;
                    break;

                case "1":
                case "KP_1":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (0);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (0);
                    else
                        return base.key_press_event (event);
                    break;

                case "2":
                case "KP_2":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (1);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (1);
                    else
                        return base.key_press_event (event);
                    break;

                case "3":
                case "KP_3":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (2);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (2);
                    else
                        return base.key_press_event (event);
                    break;

                case "4":
                case "KP_4":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (3);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (3);
                    else
                        return base.key_press_event (event);
                    break;

                case "5":
                case "KP_5":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (4);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (4);
                    else
                        return base.key_press_event (event);
                    break;

                case "6":
                case "KP_6":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (5);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (5);
                    else
                        return base.key_press_event (event);
                    break;

                case "7":
                case "KP_7":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (6);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (6);
                    else
                        return base.key_press_event (event);
                    break;

                case "8":
                case "KP_8":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (7);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (7);
                    else
                        return base.key_press_event (event);
                    break;

                case "9":
                case "KP_9":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (8);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (8);
                    else
                        return base.key_press_event (event);
                    break;

                case "0":
                case "KP_0":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (9);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (9);
                    else
                        return base.key_press_event (event);
                    break;

                case "Left":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (page_switcher.active - 1);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (category_view.switcher.active - 1);
                    else
                        return base.key_press_event (event);
                    break;

                case "Right":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (page_switcher.active + 1);
                    else if (modality == Modality.CATEGORY_VIEW)
                        category_view.switcher.set_active (category_view.switcher.active + 1);
                    else
                        return base.key_press_event (event);
                    break;

                case "Up":
                    if (modality == Modality.CATEGORY_VIEW)
                        category_view.category_switcher.selected--;

                    else if (modality == Modality.SEARCH_VIEW) {
                        search_view.selected--;
                        search_view_up ();
                    }
                    break;

                case "Down":
                    if (modality == Modality.CATEGORY_VIEW)
                        category_view.category_switcher.selected++;

                    if (modality == Modality.SEARCH_VIEW)
                        search_view.selected++;
                    if (search_view.selected > 7)
                        search_view_down ();
                    break;

                default:
                    if (!searchbar.has_focus)
                        searchbar.grab_focus ();
                    return base.key_press_event (event);

            }

            return true;

        }

        public override bool scroll_event (EventScroll event) {

            switch (event.direction.to_string ()) {
                case "GDK_SCROLL_UP":
                case "GDK_SCROLL_LEFT":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (page_switcher.active - 1);
                    else if (modality == Modality.SEARCH_VIEW)
                        search_view_up ();
                    break;
                case "GDK_SCROLL_DOWN":
                case "GDK_SCROLL_RIGHT":
                    if (modality == Modality.NORMAL_VIEW)
                        page_switcher.set_active (page_switcher.active + 1);
                    else if (modality == Modality.SEARCH_VIEW)
                        search_view_down ();
                    break;

            }

            return false;

        }

        public void hide_slingshot () {

            // Show the first page
            searchbar.text = "";

            hide ();

            // grab_remove ((Widget) this);
		    // get_current_event_device ().ungrab (Gdk.CURRENT_TIME);

        }

        public void show_slingshot () {

            reposition ();
            show_all ();
            set_modality ((Modality) view_selector.selected);

            Idle.add ( () => {
                unowned X.Display xdisplay = Gdk.X11Display.get_xdisplay (Gdk.Display.get_default ());
                var xid = Gdk.X11Window.get_xid (get_window ());
                xdisplay.raise_window (xid);
                xdisplay.set_input_focus (xid, 0, 0);
                return false;
            });
            //this.focus (0);

            //Utils.present_window (this);

        }

        private void page_left (int step = 1) {

            // Avoid unexpected behavior
            if (modality != Modality.NORMAL_VIEW)
                return;

            view_manager.slide_from (grids_list.nth_data(step));

        }

        private void page_right (int step = 1) {

            // Avoid unexpected behavior
            if (modality != Modality.NORMAL_VIEW)
                return;

            view_manager.slide_to (grids_list.nth_data (step));

        }

        private void search_view_down () {

            if (search_view.apps_showed < default_rows * 3)
                return;

            if ((search_view_position) > -(search_view.apps_showed*48)) {
                //view_manager.move (search_view, 0, search_view_position - 2*38);
                search_view_position -= 2*38;
            }

        }

        private void search_view_up () {

            if (search_view_position < 0) {
                //view_manager.move (search_view, 0, search_view_position + 2*38);
                search_view_position += 2*38;
            }

        }

        private void set_modality (Modality new_modality) {

            modality = new_modality;

            switch (modality) {
                case Modality.NORMAL_VIEW:
                    bottom.show ();
                    view_selector.show_all ();
                    page_switcher.show_all ();
                    category_view.show_page_switcher (false);
                    view_manager.slide_fade (grids_list.nth_data (page_switcher.active));
                    return;

                case Modality.CATEGORY_VIEW:
                    bottom.show ();
                    view_selector.show_all ();
                    page_switcher.hide ();
                    category_view.show_page_switcher (true);
                    view_manager.slide_fade (category_view);
                    return;

                case Modality.SEARCH_VIEW:
                    view_selector.hide ();
                    bottom.hide (); // Hide the switcher
                    //view_manager.move (grid_view, columns*130, 0); // Move the grid_view away
                    //view_manager.move (category_view, columns*130, 0);
                    view_manager.slide_fade (search_view); // Show the searchview
                    return;

            }

        }

        private async void search (string text) {

            if (text == "") {
                set_modality ((Modality) view_selector.selected);
                return;
            }

            if (modality != Modality.SEARCH_VIEW)
                set_modality (Modality.SEARCH_VIEW);
            search_view_position = 0;
            search_view.hide_all ();

            var filtered = yield app_system.search_results (text);

            foreach (App app in filtered) {
                search_view.show_app (app);
            }

            if (filtered.size != 1)
                search_view.add_command (text);

        }

        GLib.List<Gtk.Grid> grids_list;
        public void populate_grid_view () {

            page_switcher.clear_children ();
            grid_view.clear ();
            grids_list = new GLib.List<Gtk.Grid> ();
            int column = -1;
            const int max_row = 4;
            int row = max_row+1;
            const int max_col = 4;
            int page = 0;

            Gtk.Grid? grid = null;

            foreach (App app in app_system.get_apps_by_name ()) {
                column++;
                if (column >= max_col) {
                    row++;
                    column = 0;
                }
                if (row >= max_row)
                {
                    row = 0;
                    grid = new Gtk.Grid ();
                    grid.row_homogeneous = true;
                    grid.column_homogeneous = true;
                    grids_list.append (grid);

                    page++;
                    page_switcher.append (page.to_string ());
                }
                var app_entry = new AppEntry (app);

                app_entry.app_launched.connect (hide_slingshot);
                grid.attach (app_entry, row, column, 1, 1);
                app_entry.show_all ();
            }
            page_switcher.set_active (0);

            current_position = 0;

        }

        private void read_settings (bool first_start = false) {

            if (Slingshot.settings.columns > 3)
                default_columns = Slingshot.settings.columns;
            else
                default_columns = Slingshot.settings.columns = 5;

            if (Slingshot.settings.rows > 1)
                default_rows = Slingshot.settings.rows;
            else
                default_rows = Slingshot.settings.rows = 3;

        }

    }

}
