import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import { RouterModule } from '@angular/router';
import { TranslatePipe } from '@ngx-translate/core';

export interface SidebarNavigationItem {
  label: string;
  path: string;
  disabled?: boolean;
  tooltipKey?: string;
}

@Component({
  selector: 'app-sidebar',
  standalone: true,
  imports: [RouterModule, TranslatePipe],
  templateUrl: './sidebar.html',
  styleUrls: ['./sidebar.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class Sidebar {
  public readonly navigationItems = input.required<SidebarNavigationItem[]>();

  public preventWhenDisabled(event: MouseEvent, item: SidebarNavigationItem): void {
    if (!item.disabled) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
  }
}
