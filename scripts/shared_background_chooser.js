const TOTAL_IMAGES = 3;

function random(min, max) {
  const num = Math.floor(Math.random() * (max - min + 1)) + min;
  return num;
}



const pick = random(1, TOTAL_IMAGES)
//console.log(random(1, TOTAL_IMAGES))

const d = new Date();
const year = d.getFullYear();
const month = d.getMonth() + 1; 
const day = d.getDate();

const fulldate = `${year}` + `${month}` + `${day}`;
//console.log(fulldate)

const seed = fulldate % TOTAL_IMAGES
if (seed == 0) {
    const seed = seed + 1
}

//console.log(seed)


// set image based on number 
document.documentElement.style.setProperty('--bg-image', `url("/assets/background/${seed}.jpg`)
