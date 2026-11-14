import {ChangeDetectionStrategy, Component, inject, OnInit, signal} from '@angular/core';
import {Instance, ModLoader} from '../../models/instance';
import {ModdexService} from '../../services/moddex-service';
import {catchError, finalize, of} from 'rxjs';
import {TranslatePipe} from '@ngx-translate/core';
import {ButtonComponent} from '../../components/button/button';
import {InstanceCardSkeleton} from '../../components/instance-card-skeleton/instance-card-skeleton';
import {InstanceCard} from '../../components/instance-card/instance-card';

@Component({
  selector: 'app-main-page',
  standalone: true,
  imports: [
    TranslatePipe,
    ButtonComponent,
    InstanceCardSkeleton,
    InstanceCard,
  ],
  templateUrl: './main-page.html',
  styleUrl: './main-page.scss',
  changeDetection: ChangeDetectionStrategy.OnPush
})
export class MainPage implements OnInit {
  private moddexService = inject(ModdexService);

  instances = signal<Instance[]>([]);
  loading = signal(true);
  error = signal<string | null>(null);

  ngOnInit(): void {
    this.loadInstances();
  }

  loadInstances(): void {
    this.loading.set(true);
    this.error.set(null);

    this.moddexService.getInstances().pipe(
      finalize(() => this.loading.set(false)),
      catchError(err => {
        this.error.set(err.message);
        return of([]);
      })
    ).subscribe((instances: Instance[]) => {
      this.instances.set(instances);
    });
  }

  instancesMOC = signal<Instance[]>([
    {
      id: "1",
      name: "Survival World",
      categories: ["Survival", "Multiplayer"],
      description: "Eine klassische Survival-Welt mit Freunden",
      gameVersion: "1.20.1",
      modLoader: ModLoader.FORGE,
      modLoaderVersion: "47.0.0",
      modsCount: 25
    },
    {
      id: "2",
      name: "SkyBlock Challenge",
      categories: ["SkyBlock", "Challenge"],
      description: "SkyBlock mit zusätzlichen Quests und Mods",
      gameVersion: "1.19.4",
      modLoader: ModLoader.FABRIC,
      modLoaderVersion: "0.14.22",
      modsCount: 12
    },
    {
      id: "3",
      name: "Creative Sandbox",
      categories: ["Creative", "Building"],
      description: "Unbegrenzte Ressourcen zum Bauen",
      gameVersion: "1.20.2",
      modLoader: ModLoader.VANILLA,
      modsCount: 0
    },
    {
      id: "4",
      name: "Modded Adventure",
      categories: ["Adventure", "Exploration", "Modded"],
      description: "Erkunde neue Biome und Dungeons mit einem großen Modpack",
      gameVersion: "1.18.2",
      modLoader: ModLoader.FORGE,
      modLoaderVersion: "40.1.0",
      modsCount: 150
    },
    {
      id: "5",
      name: "Lorem Ipsum",
      categories: ["Lorem", "Ipsum"],
      description: "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua. At vero eos et accusam et justo duo dolores et ea rebum. Stet clita kasd gubergren, no sea takimata sanctus est Lorem ipsum dolor sit amet. Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua. At vero eos et accusam et justo duo dolores et ea rebum. Stet clita kasd gubergren, no sea takimata sanctus est Lorem ipsum dolor sit amet. Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua. At vero eos et accusam et justo duo dolores et ea rebum. Stet clita kasd gubergren, no sea takimata sanctus est Lorem ipsum dolor sit amet.\n" +
        "\n" +
        "Duis autem vel eum iriure dolor in hendrerit in vulputate velit esse molestie consequat, vel illum dolore eu feugiat nulla facilisis at vero eros et accumsan et iusto odio dignissim qui blandit praesent luptatum zzril delenit augue duis dolore te feugait nulla facilisi. Lorem ipsum dolor sit amet, consectetuer adipiscing elit, sed diam nonummy nibh euismod tincidunt ut laoreet dolore magna aliquam erat volutpat.",
      gameVersion: "1.20.1",
      modLoader: ModLoader.FABRIC,
      modLoaderVersion: "0.14.22",
      modsCount: 42
      ,
    }
  ]);
}
