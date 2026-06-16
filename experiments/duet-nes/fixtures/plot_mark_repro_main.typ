#import "@preview/lilaq:0.6.0" as lq

#set text(lang: "es")
#set math.mat(delim: "[")


= Taller 2.1: El método simplex revisado

En los siguientes problemas de optimización lineal:

1. Resolver cada uno de los problemas geométricamente.
2. Usar la _primera fase_, del método de las dos fases, para determinar la
   solución inicial para cada problema.
3. En el inciso 1 usar la segunda fase en tablas para obtener la solución óptima.
4. En el inciso 2 graficar cada iteración de la primera fase.
5. En el inciso 3 usar el _método simplex revisado_ para obtener la solución óptima.


= Inciso 1
$
"max" z = 3x_1 + x_2 \
"sujeto a" \
cases(
  x_1 - x_2  &<= -1,
  -x_1 - x_2 &<= -3,
  2x_1 + x_2 &<= 4,
  x_1 \, x_2 &>= 0
)
$

*Respuesta:* Primero, resolvemos el problema geométricamente.

// A function that returns arrays x and y given its coefficients (a, b, c)
// and allows the user to control the parameter range with t0 and t1
#let my-line(a, b, c, n, t0, t1) = {
  // Base point on the line: a*x + b*y = c
  let denom = a*a + b*b
  let px = c / denom * a
  let py = c / denom * b

  // Direction vector perpendicular to (a, b)
  let vx = -b
  let vy = a

  // Generate parameter values from t0 to t1 with n steps
  let step = (t1 - t0) / n
  let ts = range(n + 1).map(i => t0 + i * step)

  // Compute the points on the line using .map()
  let xs = ts.map(t => px + t * vx)
  let ys = ts.map(t => py + t * vy)

  (xs, ys)
}


// First line
#let (x1, y1) = my-line(1, -1, -1, 100, -10, 10)


#align(center)[#lq.diagram(
  lq.plot(
    x1, y1
  ),
  lq.plot(
    (3, 0),
    (0, 3),
  ),
  lq.plot(
    (2, 0),
    (0, 4),
  ),
  lq.line(
    (0, 0), (0, 10),
  ),
  lq.line(
    (0, 0), (10, 0),
  ),
)]



Iniciamos con el objetivo auxiliar $max - x_0$

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,7)),
  dot.c, x_1, x_2, x_3, x_4, x_5, x_0, b;
  x_3,   1,   -1,  1,   0,   0,   -1,  -1;
  x_4,  -1,   -1,  0,   1,   0,   -1,  -3;
  x_5,   2,    1,  0,   0,   1,   -1,   4;
  z,     0,    0,  0,   0,   0,   -1,   0;
)
$

El siguiente paso es convertir $x_0$ en una variable no básica. Para esto
tomamos sacamos $x_4$ de la base ya que es la más negativa.

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,7)),
  dot.c, x_1, x_2, x_3, x_4, x_5, x_0, b;
  x_3,   2,    0,  1,  -1,   0,    0,   2;
  x_0,   1,    1,  0,  -1,   0,    1,   3;
  x_5,   3,    2,  0,  -1,   1,    0,   7;
  z,     1,    1,  0,  -1,   0,    0,   3;
)
$

Ahora procedemos usualmente hasta que $x_0$ salga de la base.
Notemos la columna de $z$ es positiva en $x_1$, además
$min(2/2, 7/3) = 2/2 = 1$. Por lo tanto, luego el elemento pivote es $2$ en la
fila de $x_3$ y columna de $x_1$.

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,7)),
  dot.c, x_1, x_2, x_3,  x_4,  x_5, x_0, b;
  x_1,   1,   0,   1/2,    -1/2,   0,   0,   1;
  x_0,   0,   1,   -1/2,   -1/2,   0,   1,   2;
  x_5,   0,   2,   -3/2,    1/2,   1,   0,   4;
  z,     0,   1,   -1/2,   -1/2,   0,    0,   2;
)
$

Aún hay un elemento positivo en la columna de $z$: $x_2$. Hagamos que $x_0$
entre para terminar la primera fase.

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,7)),
  dot.c, x_1, x_2, x_3,  x_4,  x_5, x_0, b;
  x_1,   1,   0,   1/2,  -1/2, 0,   0,   1;
  x_2,   0,   1,   -1/2, -1/2, 0,   1,   2;
  x_5,   0,   0,   -1/2,  3/2,  1,   -2,  0;
  z,     0,   0,   0,    0,    0,   -1,  0;
)
$

Esto significa que la solución básica factible inicial es $x_1 = 1$, $x_2 = 2$,
$x_3 = 0$, $x_4 = 0$, $x_5 = 0$, y $z = 0$.

Queremos $z$ en términos de las variables no básicas. Inicializamos $z$ como la
función objetivo original:
$
  z - 0= 3x_1 + x_2
$

Restando la fila de $x_2$ obtenemos:
$
  z - 2 = 3x_1 + 1/2 x_3 + 1/2 x_4
$
Luego, restando la 3 veces la fila de $x_1$ obtenemos:
$
  z - 5 = -x_3 + 2 x_4
$

La tabla inicial para la segunda fase es:

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,6)),
  dot.c, x_1, x_2, x_3,  x_4,  x_5, b;
  x_1,   1,   0,   1/2,  -1/2, 0,   1;
  x_2,   0,   1,   -1/2, -1/2, 0,   2;
  x_5,   0,   0,   -1/2,  3/2,  1,   0;
  z,     0,   0,   -1,    2,    0,   5;
)
$

El siguiente elemento pivote es 3/2 en la fila de $x_5$ y columna de $x_4$.


$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,6)),
  dot.c, x_1, x_2, x_3,  x_4,  x_5, b;
  x_1,   1,   0,   1/3,   0,    1/3,   1;
  x_2,   0,   1,   -2/3,  0,    1/3,   2;
  x_4,   0,   0,   -1/3,  1,   2/3,   0;
  z,     0,   0,   -1/3,  0,  -4/3,   5;
)
$


== Inciso 2


$
"max" z = 3x_1 + x_2 \
"sujeto a" \
cases(
  x_1 - x_2  &<= -1,
  -x_1 - x_2 &<= -3,
  2x_1 + x_2 &<= 2,
  x_1 \, x_2 &>= 0
)
$

*Respuesta:* Iniciamos con el objetivo auxiliar $max - x_0$

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,7)),
  dot.c, x_1, x_2, x_3, x_4, x_5, x_0, b;
  x_3,   1,   -1,  1,   0,   0,   -1,  -1;
  x_4,  -1,   -1,  0,   1,   0,   -1,  -3;
  x_5,   2,    1,  0,   0,   1,   -1,   2;
  z,     0,    0,  0,   0,   0,   -1,   0;
)
$

El pivote es $-1$ en la fila de $x_4$ y columna de $x_0$.

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,7)),
  dot.c, x_1, x_2, x_3, x_4, x_5, x_0, b;
  x_3,   2,    0,  1,  -1,   0,    0,   2;
  x_0,   1,    1,  0,  -1,   0,    1,   3;
  x_5,   3,    2,  0,  -1,   1,    0,   5;
  z,     1,    1,  0,  -1,   0,    0,   3;
)
$

De nuevo, el pivote es $2$ en la fila de $x_3$ y columna de $x_1$.

$
mat(
  delim: "|",
  augment: #(hline: (1,4), vline: (1,7)),
  dot.c, x_1, x_2, x_3, x_4, x_5, x_0, b;
  x_3,   1,    0,  1/2,  -1/2,   0,    0,   1;
  x_0,   0,    1,  -1/2,  1/2,   0,    1,   2;
  x_5,
  z,
)
$
